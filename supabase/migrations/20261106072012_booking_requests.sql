-- Booking requests: a visitor asks WSS to book a clinic visit for them, offering
-- three preferred times. Replaces the FastAPI appointment-request routes.
--
--   submit_booking_request        anon           the public form
--   admin_list_booking_requests   admin key      dashboard list + counts per status
--   admin_set_request_status      admin key      move a request through the funnel
--   admin_delete_request          admin key      PII cleanup
--   admin_check                   admin key      cheap key check for the admin login gate
--
-- Errors follow the other functions: 22023 invalid input, P0002 not found,
-- 28000 invalid admin key. New: P0429 too many requests (rate limit).
--
-- Also adds BOOKING_REQUESTED to the referral funnel (check constraint,
-- track_referral_interaction, filtered_interactions, admin_referral_summary).
-- APPOINTMENT_CLICKED is a different, existing event (a click on the clinic's
-- own booking link) and is left as it is.

---------------------------------------------------------------------------
-- Table
---------------------------------------------------------------------------
-- place_id / place_name are a snapshot, not a FK, like referral_interactions,
-- so a request survives re-imports and reverts of the scraped data.
create table public.booking_requests (
  id              uuid primary key default gen_random_uuid(),
  reference       text not null unique check (reference ~ '^BKG-\d{4}-\d{6,}$'),
  place_id        text not null,
  place_name      text,
  full_name       text not null check (char_length(full_name) between 2 and 100),
  phone           text not null check (char_length(phone) between 7 and 30),
  email           text not null check (char_length(email) <= 254),
  status         text not null default 'new' check (status in (
                    'new', 'contacting_clinic', 'booked', 'attended',
                    'no_show', 'cancelled', 'closed')),
  admin_notes     text check (char_length(admin_notes) <= 2000),
  -- ties the booking back to the referral funnel (always set by submit_booking_request)
  referral_id     text not null check (referral_id ~ '^REF-\d{4}-\d{6,}$'),
  session_id      text,
  search_location text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index booking_requests_created_at_idx  on public.booking_requests (created_at);
create index booking_requests_status_idx      on public.booking_requests (status);
create index booking_requests_place_id_idx    on public.booking_requests (place_id);
create index booking_requests_referral_id_idx on public.booking_requests (referral_id);

create trigger booking_requests_set_updated_at
  before update on public.booking_requests
  for each row execute function public.set_updated_at();

-- The three preferred times of a request, one row each. preferred_at is a local
-- wall-clock time with no time zone (the form sends YYYY-MM-DDTHH:MM). slot_no
-- is the order the visitor ranked them in. "Exactly 3 per request" is enforced
-- by submit_booking_request, the only writer.
create table public.booking_request_times (
  id                 uuid primary key default gen_random_uuid(),
  booking_request_id uuid not null references public.booking_requests (id) on delete cascade,
  slot_no            smallint not null check (slot_no between 1 and 3),
  preferred_at       timestamp not null,
  unique (booking_request_id, slot_no),
  unique (booking_request_id, preferred_at)
);

create index booking_request_times_preferred_at_idx on public.booking_request_times (preferred_at);

-- A request as the admin UI reads it: the row plus preferred_times as an array
-- of 'YYYY-MM-DDTHH:MM' strings in slot order.
create or replace function private.booking_request_json(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select to_jsonb(br) || jsonb_build_object('preferred_times', coalesce((
           select jsonb_agg(to_char(t.preferred_at, 'YYYY-MM-DD"T"HH24:MI') order by t.slot_no)
           from public.booking_request_times t
           where t.booking_request_id = br.id), '[]'::jsonb))
  from public.booking_requests br
  where br.id = p_id;
$$;

revoke all on function private.booking_request_json(uuid) from public, anon, authenticated;

-- Collision-free BKG-YYYY-###### references (counter resets each year).
create table public.booking_counters (
  year       integer primary key,
  last_value integer not null
);

create or replace function public.next_booking_reference()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  y integer := extract(year from now() at time zone 'utc')::integer;
  n integer;
begin
  insert into public.booking_counters as bc (year, last_value)
  values (y, 1)
  on conflict (year) do update set last_value = bc.last_value + 1
  returning last_value into n;

  return format('BKG-%s-%s', y, lpad(n::text, 6, '0'));
end;
$$;

-- No policies: every read and write goes through the security-definer functions.
alter table public.booking_requests      enable row level security;
alter table public.booking_request_times enable row level security;
alter table public.booking_counters      enable row level security;
revoke all on public.booking_requests, public.booking_request_times, public.booking_counters
  from anon, authenticated;
revoke execute on function public.next_booking_reference() from public, anon, authenticated;

---------------------------------------------------------------------------
-- Funnel: BOOKING_REQUESTED as a referral event type
---------------------------------------------------------------------------
alter table public.referral_interactions
  drop constraint referral_interactions_interaction_type_check;
alter table public.referral_interactions
  add constraint referral_interactions_interaction_type_check check (interaction_type in (
    'CLINIC_VIEWED', 'PHONE_CLICKED', 'WEBSITE_CLICKED',
    'MAP_CLICKED', 'APPOINTMENT_CLICKED', 'BOOKING_REQUESTED'));

-- Same as migration 08 with BOOKING_REQUESTED allowed.
create or replace function private.filtered_interactions(
  p_clinic_id        text default null,
  p_location         text default null,
  p_interaction_type text default null,
  p_date_from        text default null,
  p_date_to          text default null,
  p_require_place    boolean default false
)
returns table (
  id               uuid,
  created_at       timestamptz,
  interaction_type text,
  place_id         text,
  address_id       integer,
  clinic_name      text,
  clinic_city      text,
  referral_id      text,
  session_id       text,
  source           text,
  search_location  text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_place text := nullif(btrim(p_clinic_id), '');
  v_loc   text := nullif(btrim(p_location), '');
  v_type  text := nullif(btrim(p_interaction_type), '');
  v_from  timestamptz;
  v_to    timestamptz;
  v_to_is_day boolean := false;
begin
  if v_type is not null and v_type not in
     ('CLINIC_VIEWED', 'PHONE_CLICKED', 'WEBSITE_CLICKED', 'MAP_CLICKED', 'APPOINTMENT_CLICKED',
      'BOOKING_REQUESTED') then
    raise exception 'invalid interaction_type: %', v_type using errcode = '22023';
  end if;

  if nullif(btrim(p_date_from), '') is not null then
    v_from := btrim(p_date_from)::timestamptz;
  end if;

  if nullif(btrim(p_date_to), '') is not null then
    if btrim(p_date_to) ~ '^\d{4}-\d{2}-\d{2}$' then
      v_to := (btrim(p_date_to)::date + 1)::timestamptz;
      v_to_is_day := true;
    else
      v_to := btrim(p_date_to)::timestamptz;
    end if;
  end if;

  return query
  select ri.id, ri.created_at, ri.interaction_type, ri.place_id, ri.address_id,
         coalesce(nullif(ca.place_name, ''), ri.place_name) as clinic_name,
         ca.city as clinic_city,
         ri.referral_id, ri.session_id, ri.source, ri.search_location
  from public.referral_interactions ri
  left join public.clinic_addresses ca on ca.address_id = ri.address_id
  where (v_place is null or ri.place_id = v_place)
    and (v_loc   is null or ca.city ilike '%' || private.like_escape(v_loc) || '%')
    and (v_type  is null or ri.interaction_type = v_type)
    and (v_type is not null or not p_require_place or ri.place_id is not null)
    and (v_from  is null or ri.created_at >= v_from)
    and (v_to    is null or (case when v_to_is_day then ri.created_at < v_to else ri.created_at <= v_to end));
end;
$$;

-- Same as migration 09 with BOOKING_REQUESTED allowed.
create or replace function public.track_referral_interaction(
  p_interaction_type text,
  p_place_id         text default null,
  p_referral_id      text default null,
  p_screening_id     text default null,
  p_session_id       text default null,
  p_source           text default null,
  p_metadata         jsonb default null,
  p_search_location  text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_referral_id text := nullif(btrim(p_referral_id), '');
  v_row         public.referral_interactions;
begin
  if p_interaction_type is null or p_interaction_type not in
     ('CLINIC_VIEWED', 'PHONE_CLICKED', 'WEBSITE_CLICKED', 'MAP_CLICKED', 'APPOINTMENT_CLICKED',
      'BOOKING_REQUESTED') then
    raise exception 'invalid interaction_type: %', p_interaction_type using errcode = '22023';
  end if;
  if v_referral_id is not null and v_referral_id !~ '^REF-\d{4}-\d{6,}$' then
    raise exception 'invalid referral_id format' using errcode = '22023';
  end if;
  if greatest(length(p_place_id), length(v_referral_id), length(p_screening_id),
              length(p_session_id), length(p_source), length(p_search_location)) > 200 then
    raise exception 'text fields must be at most 200 characters' using errcode = '22023';
  end if;
  if p_metadata is not null and (jsonb_typeof(p_metadata) <> 'object' or octet_length(p_metadata::text) > 2048) then
    raise exception 'metadata must be a JSON object of at most 2 KB' using errcode = '22023';
  end if;

  v_row := private.record_interaction(
    p_interaction_type, nullif(btrim(p_place_id), ''), v_referral_id,
    nullif(p_screening_id, ''), nullif(p_session_id, ''), nullif(p_source, ''),
    p_metadata, nullif(btrim(p_search_location), ''));

  -- clinic_id kept for the frontend's old field name.
  return to_jsonb(v_row) || jsonb_build_object('clinic_id', v_row.place_id);
end;
$$;

-- Same as migration 10 with a BOOKING_REQUESTED count in totals and by_clinic.
create or replace function public.admin_referral_summary(
  p_admin_key        text,
  p_clinic_id        text default null,
  p_location         text default null,
  p_interaction_type text default null,
  p_date_from        text default null,
  p_date_to          text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_today  text := (now() at time zone 'utc')::date::text;
  v_month  text := date_trunc('month', now() at time zone 'utc')::date::text;
  v_totals jsonb;
  v_by_clinic jsonb;
begin
  perform private.require_admin(p_admin_key);

  select jsonb_build_object(
           'total_referral_visits',       count(distinct f.referral_id),
           'total_events',                count(*),
           'clinics_receiving_referrals', count(distinct f.place_id),
           'APPOINTMENT_CLICKED', count(*) filter (where f.interaction_type = 'APPOINTMENT_CLICKED'),
           'BOOKING_REQUESTED',   count(*) filter (where f.interaction_type = 'BOOKING_REQUESTED'),
           'CLINIC_VIEWED',       count(*) filter (where f.interaction_type = 'CLINIC_VIEWED'),
           'MAP_CLICKED',         count(*) filter (where f.interaction_type = 'MAP_CLICKED'),
           'PHONE_CLICKED',       count(*) filter (where f.interaction_type = 'PHONE_CLICKED'),
           'WEBSITE_CLICKED',     count(*) filter (where f.interaction_type = 'WEBSITE_CLICKED'))
  into v_totals
  from private.filtered_interactions(p_clinic_id, p_location, p_interaction_type, p_date_from, p_date_to) f;

  v_totals := v_totals || jsonb_build_object(
    'referrals_today',
      (select count(*) from private.filtered_interactions(p_clinic_id, p_location, p_interaction_type, v_today, null)),
    'referrals_this_month',
      (select count(*) from private.filtered_interactions(p_clinic_id, p_location, p_interaction_type, v_month, null)));

  select coalesce(jsonb_agg(c.obj order by c.total desc, c.place_id), '[]'::jsonb)
  into v_by_clinic
  from (
    select f.place_id, count(*) as total,
           jsonb_build_object(
             'clinic_id',           f.place_id,
             'clinic_name',         max(f.clinic_name),
             'total',               count(*),
             'APPOINTMENT_CLICKED', count(*) filter (where f.interaction_type = 'APPOINTMENT_CLICKED'),
             'BOOKING_REQUESTED',   count(*) filter (where f.interaction_type = 'BOOKING_REQUESTED'),
             'CLINIC_VIEWED',       count(*) filter (where f.interaction_type = 'CLINIC_VIEWED'),
             'MAP_CLICKED',         count(*) filter (where f.interaction_type = 'MAP_CLICKED'),
             'PHONE_CLICKED',       count(*) filter (where f.interaction_type = 'PHONE_CLICKED'),
             'WEBSITE_CLICKED',     count(*) filter (where f.interaction_type = 'WEBSITE_CLICKED')) as obj
    from private.filtered_interactions(p_clinic_id, p_location, p_interaction_type, p_date_from, p_date_to) f
    where f.place_id is not null
    group by f.place_id
  ) c;

  return jsonb_build_object('totals', v_totals, 'by_clinic', v_by_clinic);
end;
$$;

---------------------------------------------------------------------------
-- Public: submit a booking request
--
-- Returns {reference}. A non-empty p_company is a honeypot field: bots fill
-- it, people never see it. It gets a fake success and nothing is stored.
--
-- preferred_times are wall-clock 'YYYY-MM-DDTHH:MM' strings with no zone. A
-- slot counts as past only if it is past in UTC-12 (the earliest clock on
-- Earth), so nobody west of UTC is turned away for a slot that is still ahead
-- for them. Slots must also be within a year.
--
-- Rate limits (counted from this table): 5 requests per session per hour,
-- 5 per email or phone number per 24 hours.
---------------------------------------------------------------------------
create or replace function public.submit_booking_request(
  p_place_id         text,
  p_full_name        text,
  p_phone            text,
  p_email            text,
  p_preferred_times  text[],
  p_referral_id      text default null,
  p_session_id       text default null,
  p_search_location  text default null,
  p_company          text default null
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
  v_ts          timestamp;
  v_seen        timestamp[] := '{}';
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
  foreach v_slot in array p_preferred_times loop
    if v_slot is null or v_slot !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$' then
      raise exception 'preferred times must look like YYYY-MM-DDTHH:MM' using errcode = '22023';
    end if;
    begin
      v_ts := replace(v_slot, 'T', ' ')::timestamp;
    exception when others then
      raise exception 'preferred time % is not a real date and time', v_slot using errcode = '22023';
    end;
    if to_char(v_ts, 'YYYY-MM-DD"T"HH24:MI') <> v_slot then   -- e.g. 24:00 rolls to the next day
      raise exception 'preferred time % is not a real date and time', v_slot using errcode = '22023';
    end if;
    if v_ts < v_earliest then
      raise exception 'preferred times must not be in the past' using errcode = '22023';
    end if;
    if v_ts > v_latest then
      raise exception 'preferred times must be within the next year' using errcode = '22023';
    end if;
    if v_ts = any (v_seen) then
      raise exception 'preferred times must be 3 different times' using errcode = '22023';
    end if;
    v_seen := v_seen || v_ts;
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

  -- v_seen holds the validated slots in the order the visitor gave them.
  insert into public.booking_request_times (booking_request_id, slot_no, preferred_at)
  select v_id, u.n::smallint, u.t
  from unnest(v_seen) with ordinality as u(t, n);

  return jsonb_build_object('reference', v_ref);
end;
$$;

---------------------------------------------------------------------------
-- Admin: list requests
--
-- Returns {requests, total, counts_by_status}. total follows every filter;
-- counts_by_status follows the place and text filters but not the status
-- filter, and always lists all seven statuses, so the dashboard tabs keep
-- their numbers while one tab is selected. p_query matches name, email,
-- phone, reference and clinic name.
---------------------------------------------------------------------------
create or replace function public.admin_list_booking_requests(
  p_admin_key text,
  p_status    text default null,
  p_query     text default null,
  p_place_id  text default null,
  p_limit     integer default 50,
  p_offset    integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_status  text := nullif(btrim(p_status), '');
  v_q       text := nullif(btrim(p_query), '');
  v_place   text := nullif(btrim(p_place_id), '');
  v_pattern text;
  v_total   integer;
  v_rows    jsonb;
  v_counts  jsonb;
begin
  perform private.require_admin(p_admin_key);

  if v_status is not null and v_status not in
     ('new', 'contacting_clinic', 'booked', 'attended', 'no_show', 'cancelled', 'closed') then
    raise exception 'invalid status: %', v_status using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 1000 then
    raise exception 'limit must be between 1 and 1000' using errcode = '22023';
  end if;
  if p_offset is null or p_offset < 0 then
    raise exception 'offset must be 0 or more' using errcode = '22023';
  end if;

  v_pattern := '%' || private.like_escape(coalesce(v_q, '')) || '%';

  with base as (
    select br.*
    from public.booking_requests br
    where (v_place is null or br.place_id = v_place)
      and (v_q is null
           or br.full_name  ilike v_pattern or br.email      ilike v_pattern
           or br.phone      ilike v_pattern or br.reference  ilike v_pattern
           or br.place_name ilike v_pattern)
  ),
  page as (
    select b.*
    from base b
    where v_status is null or b.status = v_status
    order by b.created_at desc, b.id
    limit p_limit offset p_offset
  )
  select (select count(*) from base b where v_status is null or b.status = v_status),
         coalesce((select jsonb_agg(private.booking_request_json(p.id) order by p.created_at desc, p.id)
                   from page p), '[]'::jsonb),
         (select jsonb_object_agg(s.status, coalesce(c.n, 0))
          from unnest(array['new', 'contacting_clinic', 'booked', 'attended',
                            'no_show', 'cancelled', 'closed']) as s(status)
          left join (select b.status, count(*) as n from base b group by b.status) c
                 on c.status = s.status)
  into v_total, v_rows, v_counts;

  return jsonb_build_object('requests', v_rows, 'total', v_total, 'counts_by_status', v_counts);
end;
$$;

---------------------------------------------------------------------------
-- Admin: set a request's status. p_note replaces admin_notes when given
-- (an empty string clears it); NULL leaves the existing note alone.
---------------------------------------------------------------------------
create or replace function public.admin_set_request_status(
  p_admin_key  text,
  p_request_id uuid,
  p_status     text,
  p_note       text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.booking_requests;
begin
  perform private.require_admin(p_admin_key);

  if p_status is null or p_status not in
     ('new', 'contacting_clinic', 'booked', 'attended', 'no_show', 'cancelled', 'closed') then
    raise exception 'invalid status: %', p_status using errcode = '22023';
  end if;
  if char_length(p_note) > 2000 then
    raise exception 'note must be at most 2000 characters' using errcode = '22023';
  end if;

  update public.booking_requests br
  set status      = p_status,
      admin_notes = case when p_note is null then br.admin_notes else nullif(btrim(p_note), '') end
  where br.id = p_request_id
  returning * into v_row;

  if not found then
    raise exception 'unknown request id' using errcode = 'P0002';
  end if;

  return private.booking_request_json(v_row.id);
end;
$$;

---------------------------------------------------------------------------
-- Admin: delete one request (PII retention); its preferred times go with it
-- (on delete cascade). The BOOKING_REQUESTED event stays
-- in the referral log; it holds only the reference, no personal data.
---------------------------------------------------------------------------
create or replace function public.admin_delete_request(p_admin_key text, p_request_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_admin(p_admin_key);
  delete from public.booking_requests where id = p_request_id;
  return found;
end;
$$;

---------------------------------------------------------------------------
-- Admin: is this key valid? Returns true, or raises 28000 like every admin call.
---------------------------------------------------------------------------
create or replace function public.admin_check(p_admin_key text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_admin(p_admin_key);
  return true;
end;
$$;

---------------------------------------------------------------------------
-- Grants: revoke from public, then grant to anon and authenticated. The admin
-- functions are callable by anon; the key check is inside each one.
-- (create or replace above keeps the existing grants on the three rewritten
-- funnel functions.)
---------------------------------------------------------------------------
revoke all on function public.submit_booking_request(text, text, text, text, text[], text, text, text, text) from public, anon, authenticated;
revoke all on function public.admin_list_booking_requests(text, text, text, text, integer, integer) from public, anon, authenticated;
revoke all on function public.admin_set_request_status(text, uuid, text, text) from public, anon, authenticated;
revoke all on function public.admin_delete_request(text, uuid) from public, anon, authenticated;
revoke all on function public.admin_check(text) from public, anon, authenticated;

grant execute on function public.submit_booking_request(text, text, text, text, text[], text, text, text, text) to anon, authenticated;
grant execute on function public.admin_list_booking_requests(text, text, text, text, integer, integer) to anon, authenticated;
grant execute on function public.admin_set_request_status(text, uuid, text, text) to anon, authenticated;
grant execute on function public.admin_delete_request(text, uuid) to anon, authenticated;
grant execute on function public.admin_check(text) to anon, authenticated;
