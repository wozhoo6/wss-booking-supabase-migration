-- Shared helpers for the API functions (migrations 09 and 10).
-- Everything here lives in the `private` schema, which the REST API does not
-- expose, and only the API functions (owned by postgres) call it.

create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- Supabase's default privileges grant SELECT on new public views to the API
-- roles. The views are security_invoker and RLS has no policies, so they would
-- only return empty rows, but deny them outright: all reads go through functions.
revoke all on public.places, public.place_registered_clinics, public.place_dermatologists
  from anon, authenticated;

---------------------------------------------------------------------------
-- Shared admin key (temporary, until Supabase Auth admins replace it)
---------------------------------------------------------------------------
create table private.admin_settings (
  id         boolean primary key default true check (id),  -- single row
  key_hash   bytea not null,
  updated_at timestamptz not null default now()
);

-- Run once from the SQL editor:  select private.set_admin_key('<your key>');
create or replace function private.set_admin_key(p_key text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_key is null or length(p_key) < 12 then
    raise exception 'admin key must be at least 12 characters' using errcode = '22023';
  end if;

  insert into private.admin_settings (id, key_hash)
  values (true, extensions.digest(p_key, 'sha256'))
  on conflict (id) do update set key_hash = excluded.key_hash, updated_at = now();
end;
$$;

-- Raises errcode 28000 'invalid admin key' unless the key matches.
create or replace function private.require_admin(p_key text)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_hash bytea;
begin
  select key_hash into v_hash from private.admin_settings where id;

  if v_hash is null or p_key is null or extensions.digest(p_key, 'sha256') <> v_hash then
    raise exception 'invalid admin key' using errcode = '28000';
  end if;
end;
$$;

---------------------------------------------------------------------------
-- Small utilities
---------------------------------------------------------------------------

-- Public search hides any CLOSED_* Google status. NULL counts as open.
create or replace function private.is_public_status(p_status text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_status is null or p_status not like 'CLOSED\_%';
$$;

-- Escapes LIKE wildcards in user input so '%' and '_' match literally.
create or replace function private.like_escape(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select replace(replace(replace(p_text, '\', '\\'), '%', '\%'), '_', '\_');
$$;

-- One CSV cell: always quoted, quotes doubled, and a leading = + - @ neutralised
-- so a spreadsheet never evaluates user-typed text (search_location) as a formula.
create or replace function private.csv_cell(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select '"' || replace(
    case when coalesce(p_value, '') ~ '^[=+\-@\t\r]' then '''' || p_value else coalesce(p_value, '') end,
    '"', '""') || '"';
$$;

---------------------------------------------------------------------------
-- Clinic object (one Google place), in the shape the React pages read
---------------------------------------------------------------------------
create or replace function private.place_json(p_place_id text, p_distance_km double precision default null)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id',              p.place_id,
    'name',            p.place_name,
    'address',         p.address,
    'city',            p.city,
    'state',           p.place_state,
    'zip',             p.zip,
    'latitude',        p.lat,
    'longitude',       p.lng,
    'phone',           nullif(p.phone, ''),
    'website',         nullif(p.website, ''),
    'rating',          p.rating,
    'review_count',    p.review_count,
    'business_status', p.business_status,
    'priority_rank',   p.priority_rank,
    'distance_km',     round(p_distance_km::numeric, 2),
    'primary_dermatologist', (
      select jsonb_build_object('name', d.name, 'specialization', null)
      from public.place_dermatologists d
      where d.place_id = p.place_id and d.confidence = 'high'
      order by d.name, d.npi
      limit 1),
    -- Fields the old app had but the scraped data does not.
    'description',   null,
    'opening_hours', '{}'::jsonb,
    'services',      '[]'::jsonb,
    'booking_url',   null
  )
  from public.places p
  where p.place_id = p_place_id;
$$;

---------------------------------------------------------------------------
-- Referral filters shared by the admin summary, log and CSV export
---------------------------------------------------------------------------
-- p_clinic_id        a place_id
-- p_location         ILIKE on the place's city
-- p_interaction_type one of the five event types
-- p_date_from/to     ISO date or timestamp, inclusive; a date-only p_date_to covers that whole day (UTC)
-- p_require_place    drop rows with no place unless an event type is filtered (log and export)
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
     ('CLINIC_VIEWED', 'PHONE_CLICKED', 'WEBSITE_CLICKED', 'MAP_CLICKED', 'APPOINTMENT_CLICKED') then
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

---------------------------------------------------------------------------
-- Insert one referral event (shared by track_referral_interaction and log_redirect).
-- Callers validate their inputs; this only snapshots the place and mints an id.
---------------------------------------------------------------------------
create or replace function private.record_interaction(
  p_interaction_type text,
  p_place_id         text,
  p_referral_id      text,
  p_screening_id     text,
  p_session_id       text,
  p_source           text,
  p_metadata         jsonb,
  p_search_location  text
)
returns public.referral_interactions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_address_id integer;
  v_place_name text;
  v_row        public.referral_interactions;
begin
  if p_place_id is not null then
    select p.address_id, p.place_name into v_address_id, v_place_name
    from public.places p
    where p.place_id = p_place_id;

    if not found then
      raise exception 'unknown place_id: %', p_place_id using errcode = 'P0002';
    end if;
  end if;

  insert into public.referral_interactions
    (referral_id, screening_id, session_id, address_id, place_id, place_name,
     interaction_type, source, metadata, search_location)
  values
    (coalesce(p_referral_id, public.next_referral_id()), p_screening_id, p_session_id,
     v_address_id, p_place_id, v_place_name, p_interaction_type,
     coalesce(p_source, 'ai_screening_results'), coalesce(p_metadata, '{}'::jsonb),
     p_search_location)
  returning * into v_row;

  return v_row;
end;
$$;

-- Nothing in `private` is callable through the API.
revoke all on all functions in schema private from public, anon, authenticated;
revoke all on all tables    in schema private from public, anon, authenticated;
