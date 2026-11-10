-- Public API (anon). Called from the WSS frontend with supabase.rpc(...).
-- Replaces the FastAPI routes /api/clinics/nearby, /api/clinics/search,
-- /api/clinics/{id} and /api/referrals/interactions. log_redirect backs the
-- clinic-redirect Edge Function and is service_role only.
--
-- Errors use errcode 22023 (invalid input) and P0002 (not found).

---------------------------------------------------------------------------
-- Nearby: pinned places first, then nearest
---------------------------------------------------------------------------
create or replace function public.nearby_places(
  p_lat       double precision,
  p_lng       double precision,
  p_radius_km double precision default 25,
  p_limit     integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_point   extensions.geography;
  v_clinics jsonb;
begin
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'lat must be between -90 and 90 and lng between -180 and 180' using errcode = '22023';
  end if;
  if p_radius_km is null or p_radius_km <= 0 or p_radius_km > 200 then
    raise exception 'radius_km must be greater than 0 and at most 200' using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'limit must be between 1 and 100' using errcode = '22023';
  end if;

  v_point := extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography;

  with hits as (
    select p.place_id, p.priority_rank,
           extensions.st_distance(p.location, v_point) as dist_m
    from public.places p
    where extensions.st_dwithin(p.location, v_point, p_radius_km * 1000)
      and private.is_public_status(p.business_status)
    order by p.priority_rank asc nulls last, dist_m, p.place_id
    limit p_limit
  )
  select coalesce(jsonb_agg(private.place_json(h.place_id, h.dist_m / 1000.0)
                            order by h.priority_rank asc nulls last, h.dist_m, h.place_id),
                  '[]'::jsonb)
  into v_clinics
  from hits h;

  return jsonb_build_object('clinics', v_clinics, 'count', jsonb_array_length(v_clinics));
end;
$$;

---------------------------------------------------------------------------
-- Search by ZIP (exact, first 5 digits) or by city / address / name
---------------------------------------------------------------------------
create or replace function public.search_places(
  p_location text,
  p_limit    integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_q       text := btrim(coalesce(p_location, ''));
  v_zip     text;
  v_pattern text;
  v_clinics jsonb;
begin
  if v_q = '' then
    raise exception 'location is required' using errcode = '22023';
  end if;
  if length(v_q) > 100 then
    raise exception 'location must be at most 100 characters' using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'limit must be between 1 and 100' using errcode = '22023';
  end if;

  if v_q ~ '^\d{5}(-?\d{4})?$' then
    v_zip := left(v_q, 5);
  else
    v_pattern := '%' || private.like_escape(v_q) || '%';
  end if;

  with hits as (
    select p.place_id, p.priority_rank, p.place_name
    from public.places p
    where private.is_public_status(p.business_status)
      and (case
             when v_zip is not null then p.zip = v_zip
             else p.city ilike v_pattern or p.address ilike v_pattern or p.place_name ilike v_pattern
           end)
    order by p.priority_rank asc nulls last, lower(p.place_name), p.place_id
    limit p_limit
  )
  select coalesce(jsonb_agg(private.place_json(h.place_id)
                            order by h.priority_rank asc nulls last, lower(h.place_name), h.place_id),
                  '[]'::jsonb)
  into v_clinics
  from hits h;

  return jsonb_build_object('clinics', v_clinics, 'count', jsonb_array_length(v_clinics));
end;
$$;

---------------------------------------------------------------------------
-- One place with its high-confidence dermatologists. NULL = not found / closed.
---------------------------------------------------------------------------
create or replace function public.get_place(p_place_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_status text;
begin
  select p.business_status into v_status
  from public.places p
  where p.place_id = p_place_id;

  if not found or not private.is_public_status(v_status) then
    return null;
  end if;

  return private.place_json(p_place_id) || jsonb_build_object(
    'dermatologists', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', d.npi, 'name', d.name,
               'specialization', null, 'profile_bio', null, 'photo_url', null)
             order by d.name, d.npi)
      from public.place_dermatologists d
      where d.place_id = p_place_id and d.confidence = 'high'), '[]'::jsonb));
end;
$$;

---------------------------------------------------------------------------
-- Record one referral event. Mints referral_id when it is not given.
-- Anyone can call this, so every input is bounded.
---------------------------------------------------------------------------
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
     ('CLINIC_VIEWED', 'PHONE_CLICKED', 'WEBSITE_CLICKED', 'MAP_CLICKED', 'APPOINTMENT_CLICKED') then
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

---------------------------------------------------------------------------
-- Website / appointment click for the clinic-redirect Edge Function.
-- Logs the event, then returns the URL to 302 to. Lenient with tracking ids
-- (a bad one is replaced or trimmed) so a click is never blocked by them.
---------------------------------------------------------------------------
create or replace function public.log_redirect(
  p_place_id        text,
  p_type            text,
  p_referral_id     text default null,
  p_session_id      text default null,
  p_screening_id    text default null,
  p_search_location text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status      text;
  v_url         text;
  v_referral_id text := nullif(btrim(p_referral_id), '');
  v_row         public.referral_interactions;
begin
  if p_type is null or p_type not in ('website', 'appointment') then
    raise exception 'type must be website or appointment' using errcode = '22023';
  end if;

  select p.business_status, nullif(btrim(p.website), '') into v_status, v_url
  from public.places p
  where p.place_id = p_place_id;

  -- No booking_url in the scraped data: appointment falls back to the website.
  if not found or not private.is_public_status(v_status)
     or v_url is null or v_url !~* '^https?://' then
    raise exception 'place not found or has no website' using errcode = 'P0002';
  end if;

  if v_referral_id is not null and v_referral_id !~ '^REF-\d{4}-\d{6,}$' then
    v_referral_id := null;  -- mint a fresh one instead of failing the click
  end if;

  v_row := private.record_interaction(
    case p_type when 'website' then 'WEBSITE_CLICKED' else 'APPOINTMENT_CLICKED' end,
    p_place_id, v_referral_id,
    left(nullif(p_screening_id, ''), 200), left(nullif(p_session_id, ''), 200), null, null,
    left(nullif(btrim(p_search_location), ''), 200));

  return jsonb_build_object('url', v_url, 'referral_id', v_row.referral_id);
end;
$$;

---------------------------------------------------------------------------
-- Grants
---------------------------------------------------------------------------
revoke all on function public.nearby_places(double precision, double precision, double precision, integer) from public, anon, authenticated;
revoke all on function public.search_places(text, integer) from public, anon, authenticated;
revoke all on function public.get_place(text) from public, anon, authenticated;
revoke all on function public.track_referral_interaction(text, text, text, text, text, text, jsonb, text) from public, anon, authenticated;
revoke all on function public.log_redirect(text, text, text, text, text, text) from public, anon, authenticated;

grant execute on function public.nearby_places(double precision, double precision, double precision, integer) to anon, authenticated;
grant execute on function public.search_places(text, integer) to anon, authenticated;
grant execute on function public.get_place(text) to anon, authenticated;
grant execute on function public.track_referral_interaction(text, text, text, text, text, text, jsonb, text) to anon, authenticated;
grant execute on function public.log_redirect(text, text, text, text, text, text) to service_role;

-- Helpers from earlier migrations that the API roles must not call directly.
revoke all on function public.set_updated_at() from public, anon, authenticated;
revoke all on function public.is_admin() from public, anon;
