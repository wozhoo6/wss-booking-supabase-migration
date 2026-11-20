-- Admin API: one pagination contract everywhere.
--
-- Every admin function that returns a list now takes p_limit / p_offset and
-- reports total, limit, offset and has_more next to its rows, so no list can
-- grow past what one call is willing to return:
--
--   admin_list_places            same signature; single pass; + limit/offset/has_more
--   admin_referral_log           same signature; single pass; + limit/offset/has_more
--   admin_list_booking_requests  same signature;              + limit/offset/has_more
--   admin_referral_summary       + p_limit/p_offset for by_clinic (default 1000)
--   admin_referral_export_csv    + p_limit/p_offset (default 5000); RETURNS jsonb now
--   admin_referral_trail         + p_limit/p_offset (default 500)
--
-- admin_get_place is left alone: its lists (addresses, doctors, registered
-- clinics) belong to one place and are bounded by that place.
--
-- Where the signature changes, the old function is dropped first so PostgREST
-- never sees two overloads (PGRST203). Existing keys keep their meaning.
--
-- BREAKING for callers: admin_referral_export_csv used to return the whole CSV
-- as text; it now returns {csv, count, total, limit, offset, has_more}. The
-- header row is only in the page with offset 0, and every page ends with CRLF,
-- so pages can be concatenated as they arrive.

---------------------------------------------------------------------------
-- admin_list_places: total from the same pass as the page.
-- (private.place_listing is security definer, so it is never inlined and was
-- evaluated twice per call before.)
---------------------------------------------------------------------------
create or replace function public.admin_list_places(
  p_admin_key text,
  p_search    text default null,
  p_limit     integer default 50,
  p_offset    integer default 0,
  p_missing   text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_q       text := nullif(btrim(p_search), '');
  v_missing text := nullif(btrim(p_missing), '');
  v_total   integer;
  v_clinics jsonb;
begin
  perform private.require_admin(p_admin_key);

  if p_limit is null or p_limit < 1 or p_limit > 1000 then
    raise exception 'limit must be between 1 and 1000' using errcode = '22023';
  end if;
  if p_offset is null or p_offset < 0 then
    raise exception 'offset must be 0 or more' using errcode = '22023';
  end if;
  if v_missing is not null and v_missing not in
     ('description', 'website', 'phone', 'hours', 'dermatologists', 'any') then
    raise exception 'invalid missing filter: %', v_missing using errcode = '22023';
  end if;

  -- The page is cut first; referral_count is only computed for its rows.
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id', pg.place_id, 'name', pg.place_name, 'city', pg.city, 'zip', pg.zip,
             'business_status', pg.business_status, 'priority_rank', pg.priority_rank,
             'referral_count', (select count(*) from public.referral_interactions ri
                                where ri.place_id = pg.place_id),
             'has_description', pg.has_description, 'has_website', pg.has_website,
             'has_phone', pg.has_phone, 'has_hours', pg.has_hours,
             'has_dermatologists', pg.has_dermatologists)
           order by pg.priority_rank asc nulls last, lower(pg.place_name), pg.place_id),
           '[]'::jsonb),
         max(pg.total)::integer
  into v_clinics, v_total
  from (
    select f.*, count(*) over () as total
    from private.place_listing(v_q, v_missing) f
    order by f.priority_rank asc nulls last, lower(f.place_name), f.place_id
    limit p_limit offset p_offset
  ) pg;

  if v_total is null then
    if p_offset = 0 then
      v_total := 0;
    else
      select count(*)::integer into v_total from private.place_listing(v_q, v_missing);
    end if;
  end if;

  return jsonb_build_object(
    'total',    v_total,
    'limit',    p_limit,
    'offset',   p_offset,
    'has_more', p_offset + jsonb_array_length(v_clinics) < v_total,
    'clinics',  v_clinics);
end;
$$;

---------------------------------------------------------------------------
-- admin_referral_log: total from the same pass as the page.
---------------------------------------------------------------------------
create or replace function public.admin_referral_log(
  p_admin_key        text,
  p_clinic_id        text default null,
  p_location         text default null,
  p_interaction_type text default null,
  p_date_from        text default null,
  p_date_to          text default null,
  p_limit            integer default 200,
  p_offset           integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_total integer;
  v_rows  jsonb;
begin
  perform private.require_admin(p_admin_key);

  if p_limit is null or p_limit < 1 or p_limit > 1000 then
    raise exception 'limit must be between 1 and 1000' using errcode = '22023';
  end if;
  if p_offset is null or p_offset < 0 then
    raise exception 'offset must be 0 or more' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id', f.id, 'created_at', f.created_at, 'interaction_type', f.interaction_type,
             'clinic_id', f.place_id, 'clinic_name', f.clinic_name, 'clinic_city', f.clinic_city,
             'search_location', f.search_location, 'referral_id', f.referral_id,
             'session_id', f.session_id, 'source', f.source)
           || coalesce(private.place_outreach(f.place_id),
                       jsonb_build_object('match_confidence', null, 'registered_clinics', '[]'::jsonb))
           order by f.created_at desc, f.id), '[]'::jsonb),
         max(f.total)::integer
  into v_rows, v_total
  from (
    select x.*, count(*) over () as total
    from private.filtered_interactions(p_clinic_id, p_location, p_interaction_type, p_date_from, p_date_to, true) x
    order by x.created_at desc, x.id
    limit p_limit offset p_offset
  ) f;

  if v_total is null then
    if p_offset = 0 then
      v_total := 0;
    else
      select count(*)::integer into v_total
      from private.filtered_interactions(p_clinic_id, p_location, p_interaction_type, p_date_from, p_date_to, true);
    end if;
  end if;

  return jsonb_build_object(
    'total',        v_total,
    'limit',        p_limit,
    'offset',       p_offset,
    'has_more',     p_offset + jsonb_array_length(v_rows) < v_total,
    'interactions', v_rows);
end;
$$;

---------------------------------------------------------------------------
-- admin_list_booking_requests: body as in 20261106120000, plus
-- limit / offset / has_more in the result.
---------------------------------------------------------------------------
create or replace function public.admin_list_booking_requests(
  p_admin_key text,
  p_status    text default null,
  p_query     text default null,
  p_place_id  text default null,
  p_limit     integer default 50,
  p_offset    integer default 0,
  p_sort      text default 'newest'
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
  v_sort    text := coalesce(nullif(btrim(p_sort), ''), 'newest');
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
  if v_sort not in ('newest', 'oldest', 'soonest', 'patient', 'clinic', 'status') then
    raise exception 'invalid sort: %', v_sort using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 1000 then
    raise exception 'limit must be between 1 and 1000' using errcode = '22023';
  end if;
  if p_offset is null or p_offset < 0 then
    raise exception 'offset must be 0 or more' using errcode = '22023';
  end if;

  v_pattern := '%' || private.like_escape(coalesce(v_q, '')) || '%';

  with base as (
    select br.id, br.status, br.created_at, br.full_name, br.place_name,
           (select t.preferred_at
            from public.booking_request_times t
            where t.booking_request_id = br.id and t.slot_no = 1) as first_choice
    from public.booking_requests br
    where (v_place is null or br.place_id = v_place)
      and (v_q is null
           or br.full_name  ilike v_pattern or br.email      ilike v_pattern
           or br.phone      ilike v_pattern or br.reference  ilike v_pattern
           or br.place_name ilike v_pattern)
  ),
  ordered as (
    select b.id,
           row_number() over (order by
             case when v_sort = 'oldest'  then b.created_at end asc,
             case when v_sort = 'soonest' then b.first_choice end asc nulls last,
             case when v_sort = 'patient' then lower(b.full_name) end asc,
             case when v_sort = 'clinic'  then lower(b.place_name) end asc nulls last,
             case when v_sort = 'status'  then array_position(
               array['new', 'contacting_clinic', 'booked', 'attended', 'no_show', 'cancelled', 'closed'],
               b.status) end asc,
             b.created_at desc, b.id) as rn
    from base b
    where v_status is null or b.status = v_status
  ),
  page as (
    select o.id, o.rn
    from ordered o
    order by o.rn
    limit p_limit offset p_offset
  )
  select (select count(*) from base b where v_status is null or b.status = v_status),
         coalesce((select jsonb_agg(private.booking_request_json(p.id) order by p.rn)
                   from page p), '[]'::jsonb),
         (select jsonb_object_agg(s.status, coalesce(c.n, 0))
          from unnest(array['new', 'contacting_clinic', 'booked', 'attended',
                            'no_show', 'cancelled', 'closed']) as s(status)
          left join (select b.status, count(*) as n from base b group by b.status) c
                 on c.status = s.status)
  into v_total, v_rows, v_counts;

  return jsonb_build_object(
    'requests',         v_rows,
    'total',            v_total,
    'limit',            p_limit,
    'offset',           p_offset,
    'has_more',         p_offset + jsonb_array_length(v_rows) < v_total,
    'counts_by_status', v_counts);
end;
$$;

---------------------------------------------------------------------------
-- admin_referral_summary: by_clinic is paginated (most referrals first).
-- totals are unaffected. New keys: by_clinic_total / _limit / _offset / _has_more.
-- Default limit 1000 is also the maximum, so existing callers still get every
-- clinic until there are more than 1000; by_clinic_has_more says when to page.
---------------------------------------------------------------------------
drop function if exists public.admin_referral_summary(text, text, text, text, text, text);

create function public.admin_referral_summary(
  p_admin_key        text,
  p_clinic_id        text default null,
  p_location         text default null,
  p_interaction_type text default null,
  p_date_from        text default null,
  p_date_to          text default null,
  p_limit            integer default 1000,
  p_offset           integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_today     text := (now() at time zone 'utc')::date::text;
  v_month     text := date_trunc('month', now() at time zone 'utc')::date::text;
  v_totals    jsonb;
  v_by_clinic jsonb;
  v_n_clinics integer;
begin
  perform private.require_admin(p_admin_key);

  if p_limit is null or p_limit < 1 or p_limit > 1000 then
    raise exception 'limit must be between 1 and 1000' using errcode = '22023';
  end if;
  if p_offset is null or p_offset < 0 then
    raise exception 'offset must be 0 or more' using errcode = '22023';
  end if;

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

  select coalesce(jsonb_agg(c.obj order by c.total desc, c.place_id), '[]'::jsonb),
         max(c.n)::integer
  into v_by_clinic, v_n_clinics
  from (
    select g.place_id, g.total, g.obj, count(*) over () as n
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
    ) g
    order by g.total desc, g.place_id
    limit p_limit offset p_offset
  ) c;

  if v_n_clinics is null then
    if p_offset = 0 then
      v_n_clinics := 0;
    else
      select count(distinct f.place_id)::integer into v_n_clinics
      from private.filtered_interactions(p_clinic_id, p_location, p_interaction_type, p_date_from, p_date_to) f
      where f.place_id is not null;
    end if;
  end if;

  return jsonb_build_object(
    'totals',              v_totals,
    'by_clinic',           v_by_clinic,
    'by_clinic_total',     v_n_clinics,
    'by_clinic_limit',     p_limit,
    'by_clinic_offset',    p_offset,
    'by_clinic_has_more',  p_offset + jsonb_array_length(v_by_clinic) < v_n_clinics);
end;
$$;

---------------------------------------------------------------------------
-- admin_referral_export_csv: one page of the filtered log as CSV, newest first.
-- screening_id and metadata stay excluded; outreach columns use the best match.
---------------------------------------------------------------------------
drop function if exists public.admin_referral_export_csv(text, text, text, text, text, text);

create function public.admin_referral_export_csv(
  p_admin_key        text,
  p_clinic_id        text default null,
  p_location         text default null,
  p_interaction_type text default null,
  p_date_from        text default null,
  p_date_to          text default null,
  p_limit            integer default 5000,
  p_offset           integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_header text := array_to_string(array[
    'Date/Time (UTC)', 'Clinic', 'Location', 'Event Type', 'Clinic ID', 'Searched Location',
    'Referral ID', 'Session ID', 'Source', 'Match Confidence', 'Registered Name', 'NPI',
    'Registered Phone', 'Registered Address', 'Google Website'], ',');
  v_body  text;
  v_count integer;
  v_total integer;
begin
  perform private.require_admin(p_admin_key);

  if p_limit is null or p_limit < 1 or p_limit > 10000 then
    raise exception 'limit must be between 1 and 10000' using errcode = '22023';
  end if;
  if p_offset is null or p_offset < 0 then
    raise exception 'offset must be 0 or more' using errcode = '22023';
  end if;

  select string_agg(
           array_to_string(array[
             private.csv_cell(to_char(f.created_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
             private.csv_cell(f.clinic_name),
             private.csv_cell(f.clinic_city),
             private.csv_cell(f.interaction_type),
             private.csv_cell(f.place_id),
             private.csv_cell(f.search_location),
             private.csv_cell(f.referral_id),
             private.csv_cell(f.session_id),
             private.csv_cell(f.source),
             private.csv_cell(best.match_confidence),
             private.csv_cell(best.registered_name),
             private.csv_cell(best.npi),
             private.csv_cell(best.registered_phone),
             private.csv_cell(concat_ws(', ', best.registered_address, best.registered_city,
                                        concat_ws(' ', best.registered_state, best.registered_zip))),
             private.csv_cell(nullif(ca.website, ''))], ','),
           E'\r\n' order by f.created_at desc, f.id),
         count(*)::integer,
         max(f.total)::integer
  into v_body, v_count, v_total
  from (
    select x.*, count(*) over () as total
    from private.filtered_interactions(p_clinic_id, p_location, p_interaction_type, p_date_from, p_date_to, true) x
    order by x.created_at desc, x.id
    limit p_limit offset p_offset
  ) f
  left join public.clinic_addresses ca on ca.address_id = f.address_id
  left join lateral (
    select rc.* from public.place_registered_clinics rc
    where rc.place_id = f.place_id
    order by rc.confidence_order, rc.registered_name, rc.clinic_id
    limit 1
  ) best on true;

  if v_total is null then
    if p_offset = 0 then
      v_total := 0;
    else
      select count(*)::integer into v_total
      from private.filtered_interactions(p_clinic_id, p_location, p_interaction_type, p_date_from, p_date_to, true);
    end if;
  end if;

  return jsonb_build_object(
    'csv',      case when p_offset = 0 then v_header || E'\r\n' else '' end
                || coalesce(v_body || E'\r\n', ''),
    'count',    v_count,
    'total',    v_total,
    'limit',    p_limit,
    'offset',   p_offset,
    'has_more', p_offset + v_count < v_total);
end;
$$;

---------------------------------------------------------------------------
-- admin_referral_trail: events of one referral visit, oldest first, paginated.
-- NULL = unknown id (no events at all).
---------------------------------------------------------------------------
drop function if exists public.admin_referral_trail(text, text);

create function public.admin_referral_trail(
  p_admin_key   text,
  p_referral_id text,
  p_limit       integer default 500,
  p_offset      integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ref   text := btrim(p_referral_id);
  v_total integer;
  v_rows  jsonb;
begin
  perform private.require_admin(p_admin_key);

  if p_limit is null or p_limit < 1 or p_limit > 1000 then
    raise exception 'limit must be between 1 and 1000' using errcode = '22023';
  end if;
  if p_offset is null or p_offset < 0 then
    raise exception 'offset must be 0 or more' using errcode = '22023';
  end if;

  -- referral_id is indexed, so counting one visit's events is cheap.
  select count(*)::integer into v_total
  from public.referral_interactions ri
  where ri.referral_id = v_ref;

  if v_total = 0 then
    return null;
  end if;

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id', ri.id, 'created_at', ri.created_at, 'interaction_type', ri.interaction_type,
             'clinic_id', ri.place_id,
             'clinic_name', coalesce(nullif(ca.place_name, ''), ri.place_name),
             'clinic_city', ca.city, 'search_location', ri.search_location,
             'screening_id', ri.screening_id, 'session_id', ri.session_id,
             'source', ri.source, 'metadata', ri.metadata)
           order by ri.created_at, ri.id), '[]'::jsonb)
  into v_rows
  from (
    select r.*
    from public.referral_interactions r
    where r.referral_id = v_ref
    order by r.created_at, r.id
    limit p_limit offset p_offset
  ) ri
  left join public.clinic_addresses ca on ca.address_id = ri.address_id;

  return jsonb_build_object(
    'referral_id',  v_ref,
    'total',        v_total,
    'limit',        p_limit,
    'offset',       p_offset,
    'has_more',     p_offset + jsonb_array_length(v_rows) < v_total,
    'interactions', v_rows);
end;
$$;

---------------------------------------------------------------------------
-- Grants for the functions whose signature changed. The create-or-replace
-- ones above (list_places, referral_log, list_booking_requests) keep theirs.
---------------------------------------------------------------------------
revoke all on function public.admin_referral_summary(text, text, text, text, text, text, integer, integer) from public, anon, authenticated;
revoke all on function public.admin_referral_export_csv(text, text, text, text, text, text, integer, integer) from public, anon, authenticated;
revoke all on function public.admin_referral_trail(text, text, integer, integer) from public, anon, authenticated;

grant execute on function public.admin_referral_summary(text, text, text, text, text, text, integer, integer) to anon, authenticated;
grant execute on function public.admin_referral_export_csv(text, text, text, text, text, text, integer, integer) to anon, authenticated;
grant execute on function public.admin_referral_trail(text, text, integer, integer) to anon, authenticated;
