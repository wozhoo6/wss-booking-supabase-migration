-- Booking requests: each preferred slot becomes a time WINDOW (from - to).
--
--   * booking_request_times gets preferred_until (the "to" time). preferred_at stays
--     the "from" time. Existing requests keep a NULL end; nothing is backfilled.
--   * submit_booking_request now REQUIRES 3 end times (p_preferred_times_to, parallel
--     to p_preferred_times). Each window must be on one day, end after it starts, last
--     at most 12 hours, and lie inside the clinic's opening hours.
--   * Opening hours = the place's Google hours, or its manual hours when Google has
--     none (same source rule as place_json). A closed day has no hours, so no window
--     fits it. If the place has NO hours on record at all (Google and manual), the
--     hours cannot be checked and the window is accepted.
--   * Times are wall-clock times in the clinic's local time zone (no zone stored).
--   * booking_request_json keeps preferred_times (the "from" strings) so the admin page
--     keeps working, and adds preferred_windows: [{"from": "...", "to": "..."}].
--   * The Teams message shows "Mon 12 Nov 2026, 9:00 AM - 11:00 AM".
--
-- DEPLOY ORDER: the new argument is required, so the booking form must send
-- p_preferred_times_to at the same time this migration reaches the live project,
-- or submissions fail with "exactly 3 preferred end times are required".

---------------------------------------------------------------------------
-- Column
---------------------------------------------------------------------------
alter table public.booking_request_times
  add column preferred_until timestamp;

alter table public.booking_request_times
  add constraint booking_request_times_window_check
  check (preferred_until is null or preferred_until > preferred_at);

---------------------------------------------------------------------------
-- Opening hours helpers (private schema)
---------------------------------------------------------------------------
-- The periods in effect for a place: Google's rows for the address with the newest
-- hours fetch, else the manual rows. Same choice as private.place_json.
create or replace function private.effective_hour_periods(p_place_id text)
returns table (day_of_week integer, open_time time, close_day_of_week integer, close_time time)
language sql
stable
security definer
set search_path = ''
as $$
  with hs as (
    select ca.address_id
    from public.clinic_addresses ca
    where ca.place_id = p_place_id
    order by ca.hours_fetched_at desc nulls last, (ca.hours_text is not null) desc, ca.address_id
    limit 1
  )
  select h.day_of_week, h.open_time, h.close_day_of_week, h.close_time
  from public.clinic_hours h
  join hs on hs.address_id = h.address_id
  union all
  select o.day_of_week, o.open_time, o.close_day_of_week, o.close_time
  from public.place_hours_overrides o
  where o.place_id = p_place_id
    and not exists (select 1 from public.clinic_hours h join hs on hs.address_id = h.address_id);
$$;

-- 'unknown' (the place has no hours on record), 'inside' or 'outside'.
-- A window is inside when ONE period covers all of it. Periods that run past midnight
-- cover the early hours of the next day, and Saturday night wraps to Sunday.
-- (Two back-to-back periods, e.g. 08:00-12:00 and 12:00-17:00, are not merged.)
create or replace function private.window_within_hours(p_place_id text, p_from timestamp, p_to timestamp)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ws integer;  -- window start, minutes since Sunday 00:00
  v_we integer;  -- window end
begin
  if not exists (select 1 from private.effective_hour_periods(p_place_id)) then
    return 'unknown';
  end if;

  v_ws := extract(dow from p_from)::integer * 1440
          + (extract(epoch from p_from::time) / 60)::integer;
  v_we := v_ws + (extract(epoch from (p_to - p_from)) / 60)::integer;

  return case when exists (
    select 1
    from (
      select p.day_of_week * 1440 + (extract(epoch from p.open_time) / 60)::integer as s,
             p.close_day_of_week * 1440 + (extract(epoch from p.close_time) / 60)::integer as e0
      from private.effective_hour_periods(p_place_id) p
    ) x,
    lateral (select case when x.e0 <= x.s then x.e0 + 10080 else x.e0 end as e) y
    where (x.s <= v_ws and v_we <= y.e)
       or (x.s <= v_ws + 10080 and v_we + 10080 <= y.e)
  ) then 'inside' else 'outside' end;
end;
$$;

revoke all on function private.effective_hour_periods(text)                  from public, anon, authenticated;
revoke all on function private.window_within_hours(text, timestamp, timestamp) from public, anon, authenticated;

---------------------------------------------------------------------------
-- Request object: add preferred_windows (preferred_times is unchanged)
---------------------------------------------------------------------------
create or replace function private.booking_request_json(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select to_jsonb(br) || jsonb_build_object(
           'clinic_id',   br.place_id,
           'clinic_name', br.place_name,
           'preferred_times', coalesce((
             select jsonb_agg(to_char(t.preferred_at, 'YYYY-MM-DD"T"HH24:MI') order by t.slot_no)
             from public.booking_request_times t
             where t.booking_request_id = br.id), '[]'::jsonb),
           'preferred_windows', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'from', to_char(t.preferred_at,    'YYYY-MM-DD"T"HH24:MI'),
                      'to',   to_char(t.preferred_until, 'YYYY-MM-DD"T"HH24:MI'))
                    order by t.slot_no)
             from public.booking_request_times t
             where t.booking_request_id = br.id), '[]'::jsonb))
  from public.booking_requests br
  where br.id = p_id;
$$;

---------------------------------------------------------------------------
-- Teams notification: show the window. Reads the times table directly (joined on id)
-- instead of relying on columns of the transition table.
---------------------------------------------------------------------------
create or replace function private.notify_booking_to_teams()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  r     record;
begin
  select ds.decrypted_secret into v_url
  from vault.decrypted_secrets ds
  where ds.name = 'booking_flow_url';

  if v_url is null then
    return null;
  end if;

  for r in
    select br.reference,
           br.full_name,
           br.phone,
           br.email,
           br.place_name,
           string_agg(
             t.slot_no::text || ') ' || to_char(t.preferred_at, 'Dy DD Mon YYYY, FMHH12:MI AM')
               || case when t.preferred_until is not null
                       then ' ' || chr(8211) || ' ' || to_char(t.preferred_until, 'FMHH12:MI AM')
                       else '' end,
             '<br>' order by t.slot_no
           ) as times_text
    from new_rows n
    join public.booking_request_times t on t.id = n.id
    join public.booking_requests br on br.id = t.booking_request_id
    group by br.id, br.reference, br.full_name, br.phone, br.email, br.place_name
  loop
    perform net.http_post(
      url     := v_url,
      body    := jsonb_build_object(
                   'reference',  coalesce(r.reference, ''),
                   'full_name',  coalesce(r.full_name, ''),
                   'phone',      coalesce(r.phone, ''),
                   'email',      coalesce(r.email, ''),
                   'place_name', coalesce(r.place_name, ''),
                   'times_text', coalesce(r.times_text, '')
                 ),
      headers := jsonb_build_object('Content-Type', 'application/json'),
      timeout_milliseconds := 5000
    );
  end loop;

  return null;
exception when others then
  raise warning 'booking notification failed: %', sqlerrm;
  return null;
end;
$$;

---------------------------------------------------------------------------
-- submit_booking_request: same as migration 20261106072012, plus the end times.
-- A new signature, so the old function is dropped first.
---------------------------------------------------------------------------
drop function public.submit_booking_request(text, text, text, text, text[], text, text, text, text);

create function public.submit_booking_request(
  p_place_id           text,
  p_full_name          text,
  p_phone              text,
  p_email              text,
  p_preferred_times    text[],   -- 3 start times, 'YYYY-MM-DDTHH:MM'
  p_referral_id        text default null,
  p_session_id         text default null,
  p_search_location    text default null,
  p_company            text default null,
  p_preferred_times_to text[] default null   -- 3 end times, same order; required
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_place_id    text := nullif(btrim(p_place_id), '');
  v_name        text := btrim(coalesce(p_full_name, ''));
  v_phone       text := btrim(coalesce(p_phone, ''));
  v_digits      text;
  v_email       text := lower(btrim(coalesce(p_email, '')));
  v_referral_id text := nullif(btrim(p_referral_id), '');
  v_session     text := nullif(btrim(p_session_id), '');
  v_search      text := nullif(btrim(p_search_location), '');
  v_place_name  text;
  v_status      text;
  v_slot        text;
  v_slot_to     text;
  v_i           integer := 0;
  v_ts          timestamp;
  v_ts_to       timestamp;
  v_seen        timestamp[] := '{}';
  v_seen_to     timestamp[] := '{}';
  v_earliest    timestamp := now() at time zone 'Etc/GMT+12';   -- UTC-12
  v_latest      timestamp := now() at time zone 'utc' + interval '1 year';
  v_ref         text;
  v_id          uuid;
  v_event       public.referral_interactions;
begin
  -- Honeypot: look like a success, store nothing, burn no real reference.
  if nullif(btrim(p_company), '') is not null then
    return jsonb_build_object('reference', format('BKG-%s-%s',
      extract(year from now() at time zone 'utc')::integer,
      lpad((100000 + floor(random() * 900000))::integer::text, 6, '0')));
  end if;

  if v_place_id is null then
    raise exception 'place_id is required' using errcode = '22023';
  end if;
  if char_length(v_name) not between 2 and 100 then
    raise exception 'full_name must be 2 to 100 characters' using errcode = '22023';
  end if;

  if char_length(v_phone) > 30 or v_phone !~ '^[0-9+()\-.\s]+$' then
    raise exception 'phone must contain only digits, spaces and + ( ) - .' using errcode = '22023';
  end if;
  v_digits := regexp_replace(v_phone, '\D', '', 'g');
  if char_length(v_digits) not between 10 and 15 then
    raise exception 'phone must have 10 to 15 digits' using errcode = '22023';
  end if;

  if char_length(v_email) > 254 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'email is not valid' using errcode = '22023';
  end if;

  if greatest(char_length(v_place_id), char_length(v_referral_id),
              char_length(v_session), char_length(v_search)) > 200 then
    raise exception 'text fields must be at most 200 characters' using errcode = '22023';
  end if;

  if coalesce(cardinality(p_preferred_times), 0) <> 3 then
    raise exception 'exactly 3 preferred times are required' using errcode = '22023';
  end if;
  if coalesce(cardinality(p_preferred_times_to), 0) <> 3 then
    raise exception 'exactly 3 preferred end times are required (preferred_times_to)' using errcode = '22023';
  end if;

  foreach v_slot in array p_preferred_times loop
    v_i := v_i + 1;
    select u.t into v_slot_to
    from unnest(p_preferred_times_to) with ordinality as u(t, n)
    where u.n = v_i;

    if v_slot is null or v_slot !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$' then
      raise exception 'preferred times must look like YYYY-MM-DDTHH:MM' using errcode = '22023';
    end if;
    if v_slot_to is null or v_slot_to !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$' then
      raise exception 'preferred end times must look like YYYY-MM-DDTHH:MM' using errcode = '22023';
    end if;
    begin
      v_ts := replace(v_slot, 'T', ' ')::timestamp;
    exception when others then
      raise exception 'preferred time % is not a real date and time', v_slot using errcode = '22023';
    end;
    begin
      v_ts_to := replace(v_slot_to, 'T', ' ')::timestamp;
    exception when others then
      raise exception 'preferred end time % is not a real date and time', v_slot_to using errcode = '22023';
    end;
    if to_char(v_ts, 'YYYY-MM-DD"T"HH24:MI') <> v_slot then   -- e.g. 24:00 rolls to the next day
      raise exception 'preferred time % is not a real date and time', v_slot using errcode = '22023';
    end if;
    if to_char(v_ts_to, 'YYYY-MM-DD"T"HH24:MI') <> v_slot_to then
      raise exception 'preferred end time % is not a real date and time', v_slot_to using errcode = '22023';
    end if;
    if v_ts < v_earliest then
      raise exception 'preferred times must not be in the past' using errcode = '22023';
    end if;
    if v_ts > v_latest then
      raise exception 'preferred times must be within the next year' using errcode = '22023';
    end if;
    if v_ts_to <= v_ts then
      raise exception 'time window %: the end time must be after the start time', v_i using errcode = '22023';
    end if;
    if v_ts_to::date <> v_ts::date then
      raise exception 'time window %: start and end must be on the same day', v_i using errcode = '22023';
    end if;
    if v_ts_to - v_ts > interval '12 hours' then
      raise exception 'time window %: at most 12 hours long', v_i using errcode = '22023';
    end if;
    if v_ts = any (v_seen) then
      raise exception 'preferred times must be 3 different times' using errcode = '22023';
    end if;
    v_seen    := v_seen    || v_ts;
    v_seen_to := v_seen_to || v_ts_to;
  end loop;

  -- A bad tracking id must not lose the booking: drop it and mint a fresh one.
  if v_referral_id is not null and v_referral_id !~ '^REF-\d{4}-\d{6,}$' then
    v_referral_id := null;
  end if;

  select p.place_name, p.business_status into v_place_name, v_status
  from public.places p
  where p.place_id = v_place_id;

  if not found or not private.is_public_status(v_status) then
    raise exception 'place not found' using errcode = 'P0002';
  end if;

  -- Every window must fit the clinic's opening hours (unknown hours are not checked).
  for v_i in 1..3 loop
    if private.window_within_hours(v_place_id, v_seen[v_i], v_seen_to[v_i]) = 'outside' then
      raise exception 'time window %: outside the clinic opening hours', v_i using errcode = '22023';
    end if;
  end loop;

  -- Serialise requests from one email so parallel calls cannot slip past the limits.
  perform pg_advisory_xact_lock(hashtextextended('booking:' || v_email, 0));

  if v_session is not null and (
       select count(*) from public.booking_requests br
       where br.session_id = v_session and br.created_at > now() - interval '1 hour') >= 5 then
    raise exception 'too many booking requests, try again later' using errcode = 'P0429';
  end if;
  if (select count(*) from public.booking_requests br
      where br.created_at > now() - interval '24 hours'
        and (br.email = v_email or regexp_replace(br.phone, '\D', '', 'g') = v_digits)) >= 5 then
    raise exception 'too many booking requests, try again later' using errcode = 'P0429';
  end if;

  v_ref := public.next_booking_reference();

  -- Mints a referral_id when the visitor had none, so every booking has one.
  v_event := private.record_interaction(
    'BOOKING_REQUESTED', v_place_id, v_referral_id, null, v_session, null,
    jsonb_build_object('booking_reference', v_ref), v_search);

  insert into public.booking_requests
    (reference, place_id, place_name, full_name, phone, email,
     referral_id, session_id, search_location)
  values
    (v_ref, v_place_id, v_place_name, v_name, v_phone, v_email,
     v_event.referral_id, v_session, v_search)
  returning id into v_id;

  -- v_seen / v_seen_to hold the validated windows in the order the visitor gave them.
  insert into public.booking_request_times (booking_request_id, slot_no, preferred_at, preferred_until)
  select v_id, u.n::smallint, u.t, u.t_to
  from unnest(v_seen, v_seen_to) with ordinality as u(t, t_to, n);

  return jsonb_build_object('reference', v_ref);
end;
$$;

revoke all on function public.submit_booking_request(text, text, text, text, text[], text, text, text, text, text[]) from public, anon, authenticated;
grant execute on function public.submit_booking_request(text, text, text, text, text[], text, text, text, text, text[]) to anon, authenticated;
