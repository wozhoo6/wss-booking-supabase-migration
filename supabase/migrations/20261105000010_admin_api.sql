-- Admin API. Callable by anon, but every function checks p_admin_key first
-- (private.require_admin raises errcode 28000 'invalid admin key').
-- Replaces the FastAPI /api/admin/* clinic and referral routes.
--
-- Referral filters (summary, log, export) take the same five arguments:
--   p_clinic_id (place_id), p_location (city), p_interaction_type,
--   p_date_from, p_date_to (ISO date or timestamp, inclusive).

---------------------------------------------------------------------------
-- Places list (clinic filter dropdown + pinning screen). Includes closed places.
---------------------------------------------------------------------------
create or replace function public.admin_list_places(
  p_admin_key text,
  p_search    text default null,
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
  v_q       text := nullif(btrim(p_search), '');
  v_pattern text;
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

  v_pattern := '%' || private.like_escape(coalesce(v_q, '')) || '%';

  select count(*) into v_total
  from public.places p
  where v_q is null
     or p.place_name ilike v_pattern or p.city ilike v_pattern
     or p.address ilike v_pattern or p.zip = v_q;

  select coalesce(jsonb_agg(x.obj order by x.pr asc nulls last, x.nm, x.id), '[]'::jsonb)
  into v_clinics
  from (
    select p.place_id as id, p.priority_rank as pr, lower(p.place_name) as nm,
           jsonb_build_object(
             'id', p.place_id, 'name', p.place_name, 'city', p.city, 'zip', p.zip,
             'business_status', p.business_status, 'priority_rank', p.priority_rank,
             'referral_count', (select count(*) from public.referral_interactions ri
                                where ri.place_id = p.place_id)) as obj
    from public.places p
    where v_q is null
       or p.place_name ilike v_pattern or p.city ilike v_pattern
       or p.address ilike v_pattern or p.zip = v_q
    order by p.priority_rank asc nulls last, lower(p.place_name), p.place_id
    limit p_limit offset p_offset
  ) x;

  return jsonb_build_object('total', v_total, 'clinics', v_clinics);
end;
$$;

---------------------------------------------------------------------------
-- One place: clinic object, its address rows (pin targets), the registered
-- NPI clinics behind it (outreach) and every linked doctor. NULL = unknown.
---------------------------------------------------------------------------
create or replace function public.admin_get_place(p_admin_key text, p_place_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_place jsonb;
begin
  perform private.require_admin(p_admin_key);

  v_place := private.place_json(p_place_id);
  if v_place is null then
    return null;
  end if;

  return v_place || jsonb_build_object(
    'addresses', coalesce((
      select jsonb_agg(jsonb_build_object(
               'address_id', ca.address_id, 'clinic_id', ca.clinic_id,
               'place_name', ca.place_name, 'address', ca.address,
               'result_rank', ca.result_rank, 'matches_registered', ca.matches_registered,
               'name_match', ca.name_match,
               'priority_rank', ap.priority_rank, 'priority_note', ap.note)
             order by ca.address_id)
      from public.clinic_addresses ca
      left join public.address_priority ap using (address_id)
      where ca.place_id = p_place_id), '[]'::jsonb),
    'registered_clinics', coalesce((
      select jsonb_agg(to_jsonb(rc) - 'place_id' - 'confidence_order'
             order by rc.confidence_order, rc.registered_name, rc.clinic_id)
      from public.place_registered_clinics rc
      where rc.place_id = p_place_id), '[]'::jsonb),
    'dermatologists', coalesce((
      select jsonb_agg(jsonb_build_object('id', d.npi, 'name', d.name, 'confidence', d.confidence)
             order by (d.confidence = 'high') desc, d.name, d.npi)
      from public.place_dermatologists d
      where d.place_id = p_place_id), '[]'::jsonb));
end;
$$;

---------------------------------------------------------------------------
-- Pin / unpin one address (sponsored placement)
---------------------------------------------------------------------------
create or replace function public.admin_set_priority(
  p_admin_key     text,
  p_address_id    integer,
  p_priority_rank integer,
  p_note          text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.address_priority;
begin
  perform private.require_admin(p_admin_key);

  if p_priority_rank is null or p_priority_rank < 1 then
    raise exception 'priority_rank must be 1 or more' using errcode = '22023';
  end if;
  if not exists (select 1 from public.clinic_addresses where address_id = p_address_id) then
    raise exception 'unknown address_id: %', p_address_id using errcode = 'P0002';
  end if;

  insert into public.address_priority (address_id, priority_rank, note)
  values (p_address_id, p_priority_rank, nullif(btrim(p_note), ''))
  on conflict (address_id) do update
    set priority_rank = excluded.priority_rank, note = excluded.note
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

create or replace function public.admin_clear_priority(p_admin_key text, p_address_id integer)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_admin(p_admin_key);
  delete from public.address_priority where address_id = p_address_id;
  return found;
end;
$$;

---------------------------------------------------------------------------
-- Referral analytics: totals, per-type counts and per-clinic breakdown.
-- referrals_today / referrals_this_month keep the clinic, location and type
-- filters but ignore the date range (live counters, as in the old app).
---------------------------------------------------------------------------
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
-- Outreach info per place: best registered-clinic match + all of them.
---------------------------------------------------------------------------
create or replace function private.place_outreach(p_place_id text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'match_confidence', (
      select rc.match_confidence from public.place_registered_clinics rc
      where rc.place_id = p_place_id
      order by rc.confidence_order, rc.registered_name, rc.clinic_id
      limit 1),
    'registered_clinics', coalesce((
      select jsonb_agg(to_jsonb(rc) - 'place_id' - 'confidence_order'
             order by rc.confidence_order, rc.registered_name, rc.clinic_id)
      from public.place_registered_clinics rc
      where rc.place_id = p_place_id), '[]'::jsonb));
$$;

revoke all on function private.place_outreach(text) from public, anon, authenticated;

---------------------------------------------------------------------------
-- Referral event log (newest first, paginated)
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

  select count(*) into v_total
  from private.filtered_interactions(p_clinic_id, p_location, p_interaction_type, p_date_from, p_date_to, true);

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id', f.id, 'created_at', f.created_at, 'interaction_type', f.interaction_type,
             'clinic_id', f.place_id, 'clinic_name', f.clinic_name, 'clinic_city', f.clinic_city,
             'search_location', f.search_location, 'referral_id', f.referral_id,
             'session_id', f.session_id, 'source', f.source)
           || coalesce(private.place_outreach(f.place_id),
                       jsonb_build_object('match_confidence', null, 'registered_clinics', '[]'::jsonb))
           order by f.created_at desc, f.id), '[]'::jsonb)
  into v_rows
  from (
    select * from private.filtered_interactions(p_clinic_id, p_location, p_interaction_type, p_date_from, p_date_to, true) x
    order by x.created_at desc, x.id
    limit p_limit offset p_offset
  ) f;

  return jsonb_build_object('total', v_total, 'interactions', v_rows);
end;
$$;

---------------------------------------------------------------------------
-- CSV export of the whole filtered log (no paging). screening_id and
-- metadata are deliberately excluded. Outreach columns use the best match.
---------------------------------------------------------------------------
create or replace function public.admin_referral_export_csv(
  p_admin_key        text,
  p_clinic_id        text default null,
  p_location         text default null,
  p_interaction_type text default null,
  p_date_from        text default null,
  p_date_to          text default null
)
returns text
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
  v_body text;
begin
  perform private.require_admin(p_admin_key);

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
           E'\r\n' order by f.created_at desc, f.id)
  into v_body
  from private.filtered_interactions(p_clinic_id, p_location, p_interaction_type, p_date_from, p_date_to, true) f
  left join public.clinic_addresses ca on ca.address_id = f.address_id
  left join lateral (
    select rc.* from public.place_registered_clinics rc
    where rc.place_id = f.place_id
    order by rc.confidence_order, rc.registered_name, rc.clinic_id
    limit 1
  ) best on true;

  return v_header || E'\r\n' || coalesce(v_body || E'\r\n', '');
end;
$$;

---------------------------------------------------------------------------
-- Every event of one referral visit, oldest first. NULL = unknown id.
---------------------------------------------------------------------------
create or replace function public.admin_referral_trail(p_admin_key text, p_referral_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_rows jsonb;
begin
  perform private.require_admin(p_admin_key);

  select jsonb_agg(
           jsonb_build_object(
             'id', ri.id, 'created_at', ri.created_at, 'interaction_type', ri.interaction_type,
             'clinic_id', ri.place_id,
             'clinic_name', coalesce(nullif(ca.place_name, ''), ri.place_name),
             'clinic_city', ca.city, 'search_location', ri.search_location,
             'screening_id', ri.screening_id, 'session_id', ri.session_id,
             'source', ri.source, 'metadata', ri.metadata)
           order by ri.created_at, ri.id)
  into v_rows
  from public.referral_interactions ri
  left join public.clinic_addresses ca on ca.address_id = ri.address_id
  where ri.referral_id = btrim(p_referral_id);

  if v_rows is null then
    return null;
  end if;

  return jsonb_build_object('referral_id', btrim(p_referral_id), 'interactions', v_rows);
end;
$$;

---------------------------------------------------------------------------
-- Grants: anon can call these; the admin key check is inside each one.
---------------------------------------------------------------------------
revoke all on function public.admin_list_places(text, text, integer, integer) from public, anon, authenticated;
revoke all on function public.admin_get_place(text, text) from public, anon, authenticated;
revoke all on function public.admin_set_priority(text, integer, integer, text) from public, anon, authenticated;
revoke all on function public.admin_clear_priority(text, integer) from public, anon, authenticated;
revoke all on function public.admin_referral_summary(text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.admin_referral_log(text, text, text, text, text, text, integer, integer) from public, anon, authenticated;
revoke all on function public.admin_referral_export_csv(text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.admin_referral_trail(text, text) from public, anon, authenticated;

grant execute on function public.admin_list_places(text, text, integer, integer) to anon, authenticated;
grant execute on function public.admin_get_place(text, text) to anon, authenticated;
grant execute on function public.admin_set_priority(text, integer, integer, text) to anon, authenticated;
grant execute on function public.admin_clear_priority(text, integer) to anon, authenticated;
grant execute on function public.admin_referral_summary(text, text, text, text, text, text) to anon, authenticated;
grant execute on function public.admin_referral_log(text, text, text, text, text, text, integer, integer) to anon, authenticated;
grant execute on function public.admin_referral_export_csv(text, text, text, text, text, text) to anon, authenticated;
grant execute on function public.admin_referral_trail(text, text) to anon, authenticated;
