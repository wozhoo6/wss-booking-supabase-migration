-- Admin can disable a place. A disabled place disappears from every public
-- function (nearby, search, detail, redirects, booking requests) and stays
-- visible to admins, who can enable it again.
--
-- Where the flag lives: public.clinic_addresses.is_disabled.
--   * The import (import_batch) lists its insert and its ON CONFLICT update columns
--     explicitly and never names is_disabled, so a new row gets false and a
--     re-import leaves an existing value alone. Staging tables are untouched.
--   * revert_batch deletes the rows a batch created, flag included. If a disabled
--     address is reverted and imported again, it comes back enabled.
--
-- A place is disabled when ANY of its address rows is disabled (bool_or over the
-- place_id). So a sibling row imported later for an already-disabled place cannot
-- bring it back, and the choice of which row represents the place does not matter.
-- The admin function sets every address of the place at once.
--
-- How the public side is closed (fail-closed, no public function is rewritten):
--   public.places_all  every place, with is_disabled   (new; admin side)
--   public.places      same columns as before, minus disabled places
-- Every existing public function reads public.places, so they all hide disabled
-- places without being touched. The admin side reads places_all.
--
-- Side effect: private.record_interaction reads public.places, so logging a click
-- for a place that was just disabled fails with "unknown place_id" (a stale page).

---------------------------------------------------------------------------
-- Column
---------------------------------------------------------------------------
alter table public.clinic_addresses
  add column is_disabled boolean not null default false;

---------------------------------------------------------------------------
-- Views
---------------------------------------------------------------------------
create view public.places_all
with (security_invoker = true)
as
with ranked as (
  select distinct on (ca.place_id)
    ca.address_id, ca.place_id, ca.place_name, ca.address, ca.city, ca.place_state,
    ca.zip, ca.lat, ca.lng, ca.location, ca.phone, ca.website, ca.rating,
    ca.review_count, ca.business_status,
    bool_or(ca.is_disabled) over (partition by ca.place_id) as is_disabled
  from public.clinic_addresses ca
  order by ca.place_id, ca.matches_registered desc, ca.result_rank, ca.address_id
),
priority as (
  select ca.place_id, min(ap.priority_rank) as priority_rank
  from public.address_priority ap
  join public.clinic_addresses ca using (address_id)
  group by ca.place_id
)
select r.address_id, r.place_id, r.place_name, r.address, r.city, r.place_state,
       r.zip, r.lat, r.lng, r.location, r.phone, r.website, r.rating,
       r.review_count, r.business_status, p.priority_rank, r.is_disabled
from ranked r
left join priority p using (place_id);

-- Same columns, same order as before; only the disabled places are gone.
create or replace view public.places
with (security_invoker = true)
as
select pa.address_id, pa.place_id, pa.place_name, pa.address, pa.city, pa.place_state,
       pa.zip, pa.lat, pa.lng, pa.location, pa.phone, pa.website, pa.rating,
       pa.review_count, pa.business_status, pa.priority_rank
from public.places_all pa
where not pa.is_disabled;

revoke all on public.places_all from anon, authenticated;

---------------------------------------------------------------------------
-- place_json: reads places_all so admin_get_place can open a disabled place.
-- Public callers have already checked the place against public.places.
-- Output shape is unchanged (is_disabled is not added here).
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
    'phone',           coalesce(nullif(p.phone, ''), nullif(btrim(po.phone), '')),
    'website',         coalesce(nullif(p.website, ''), nullif(btrim(po.website), '')),
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
    'description', coalesce((
      select ca.description
      from public.clinic_addresses ca
      where ca.place_id = p.place_id and nullif(btrim(ca.description), '') is not null
      order by ca.description_fetched_at desc nulls last, ca.address_id
      limit 1), nullif(btrim(po.description), '')),
    'hours_text',       case when hs.has_rows then hs.hours_text else po.hours_text end,
    'hours_fetched_at', case when hs.has_rows then hs.hours_fetched_at end,
    'hours_source',     case
                          when hs.has_rows then 'google'
                          when exists (select 1 from public.place_hours_overrides o where o.place_id = p.place_id)
                            then 'manual'
                        end,
    'opening_hours',    private.opening_hours_json(hs.address_id, p.place_id),
    -- Fields the old app had but the scraped data does not.
    'services',      '[]'::jsonb,
    'booking_url',   null
  )
  from public.places_all p
  left join public.place_overrides po on po.place_id = p.place_id
  left join lateral (
    select ca.address_id, ca.hours_text, ca.hours_fetched_at,
           exists (select 1 from public.clinic_hours ch where ch.address_id = ca.address_id) as has_rows
    from public.clinic_addresses ca
    where ca.place_id = p.place_id
    order by ca.hours_fetched_at desc nulls last, (ca.hours_text is not null) desc, ca.address_id
    limit 1
  ) hs on true
  where p.place_id = p_place_id;
$$;

---------------------------------------------------------------------------
-- place_listing: lists every place (disabled included) and reports is_disabled.
-- The return type changes, so the function is dropped and created again.
---------------------------------------------------------------------------
drop function private.place_listing(text, text);

create function private.place_listing(p_search text, p_missing text)
returns table (
  place_id         text,
  priority_rank    integer,
  place_name       text,
  city             text,
  zip              text,
  business_status  text,
  has_description  boolean,
  has_website      boolean,
  has_phone        boolean,
  has_hours        boolean,
  has_dermatologists boolean,
  is_disabled      boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from (
    select
      p.place_id, p.priority_rank, p.place_name, p.city, p.zip, p.business_status,
      (exists (select 1 from public.clinic_addresses ca
               where ca.place_id = p.place_id and nullif(btrim(ca.description), '') is not null)
       or nullif(btrim(po.description), '') is not null) as has_description,
      (nullif(btrim(p.website), '') is not null or nullif(btrim(po.website), '') is not null) as has_website,
      (nullif(btrim(p.phone), '')   is not null or nullif(btrim(po.phone), '')   is not null) as has_phone,
      (exists (select 1 from public.clinic_addresses ca
               join public.clinic_hours ch on ch.address_id = ca.address_id
               where ca.place_id = p.place_id)
       or exists (select 1 from public.place_hours_overrides o where o.place_id = p.place_id)) as has_hours,
      exists (select 1 from public.place_dermatologists d
              where d.place_id = p.place_id and d.confidence = 'high') as has_dermatologists,
      p.is_disabled
    from public.places_all p
    left join public.place_overrides po on po.place_id = p.place_id
    where nullif(btrim(p_search), '') is null
       or p.place_name ilike '%' || private.like_escape(btrim(p_search)) || '%'
       or p.city       ilike '%' || private.like_escape(btrim(p_search)) || '%'
       or p.address    ilike '%' || private.like_escape(btrim(p_search)) || '%'
       or p.zip = btrim(p_search)
  ) f
  where p_missing is null
     or (case p_missing
           when 'description'    then not f.has_description
           when 'website'        then not f.has_website
           when 'phone'          then not f.has_phone
           when 'hours'          then not f.has_hours
           when 'dermatologists' then not f.has_dermatologists
           when 'any'            then not (f.has_description and f.has_website
                                           and f.has_hours and f.has_dermatologists)
         end);
$$;

revoke all on function private.place_listing(text, text) from public, anon, authenticated;

---------------------------------------------------------------------------
-- admin_list_places: same signature and pagination as 20261114000003;
-- each clinic gains is_disabled.
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
             'is_disabled', pg.is_disabled,
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
-- admin_get_place: same as 20261112000001, plus is_disabled (top level and per
-- address); the scraped website/phone read places_all so a disabled place shows them.
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
    'is_disabled', (select pa.is_disabled from public.places_all pa where pa.place_id = p_place_id),
    'addresses', coalesce((
      select jsonb_agg(jsonb_build_object(
               'address_id', ca.address_id, 'clinic_id', ca.clinic_id,
               'place_name', ca.place_name, 'address', ca.address,
               'result_rank', ca.result_rank, 'matches_registered', ca.matches_registered,
               'name_match', ca.name_match,
               'is_disabled', ca.is_disabled,
               'hours_fetched_at', ca.hours_fetched_at,
               'description_fetched_at', ca.description_fetched_at,
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
      select jsonb_agg(jsonb_build_object(
               'id', coalesce(d.npi, 'manual-' || d.link_id), 'npi', d.npi, 'name', d.name,
               'confidence', d.confidence, 'source', d.source, 'link_id', d.link_id)
             order by (d.confidence = 'high') desc, d.name, d.npi, d.link_id)
      from public.place_dermatologists d
      where d.place_id = p_place_id), '[]'::jsonb),
    'hidden_dermatologists', coalesce((
      select jsonb_agg(jsonb_build_object('npi', h.npi, 'name', dd.name) order by dd.name, h.npi)
      from public.place_dermatologist_hidden h
      left join public.dermatologists dd on dd.npi = h.npi
      where h.place_id = p_place_id), '[]'::jsonb),
    'scraped', jsonb_build_object(
      'description', (
        select ca.description from public.clinic_addresses ca
        where ca.place_id = p_place_id and nullif(btrim(ca.description), '') is not null
        order by ca.description_fetched_at desc nulls last, ca.address_id
        limit 1),
      'website', (select nullif(btrim(p.website), '') from public.places_all p where p.place_id = p_place_id),
      'phone',   (select nullif(btrim(p.phone), '')   from public.places_all p where p.place_id = p_place_id),
      'has_hours', exists (
        select 1 from public.clinic_addresses ca
        join public.clinic_hours ch on ch.address_id = ca.address_id
        where ca.place_id = p_place_id)),
    'manual', jsonb_build_object(
      'description', (select po.description from public.place_overrides po where po.place_id = p_place_id),
      'website',     (select po.website     from public.place_overrides po where po.place_id = p_place_id),
      'phone',       (select po.phone       from public.place_overrides po where po.place_id = p_place_id),
      'hours_text',  (select po.hours_text  from public.place_overrides po where po.place_id = p_place_id),
      'updated_at',  (select po.updated_at  from public.place_overrides po where po.place_id = p_place_id),
      'hours', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'day_of_week', o.day_of_week, 'open_time', left(o.open_time::text, 5),
                 'close_day_of_week', o.close_day_of_week, 'close_time', left(o.close_time::text, 5))
               order by o.day_of_week, o.open_time)
        from public.place_hours_overrides o
        where o.place_id = p_place_id), '[]'::jsonb)));
end;
$$;

---------------------------------------------------------------------------
-- admin_set_place_disabled: disables or enables a place by setting the flag on
-- every one of its addresses. Returns the refreshed admin_get_place object.
-- Priority rows, overrides and referral history are left as they are.
---------------------------------------------------------------------------
create or replace function public.admin_set_place_disabled(
  p_admin_key text,
  p_place_id  text,
  p_disabled  boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_admin(p_admin_key);

  if p_disabled is null then
    raise exception 'disabled must be true or false' using errcode = '22023';
  end if;
  if not exists (select 1 from public.clinic_addresses where place_id = p_place_id) then
    raise exception 'unknown place_id: %', p_place_id using errcode = 'P0002';
  end if;

  update public.clinic_addresses
     set is_disabled = p_disabled
   where place_id = p_place_id
     and is_disabled is distinct from p_disabled;

  return public.admin_get_place(p_admin_key, p_place_id);
end;
$$;

revoke all on function public.admin_set_place_disabled(text, text, boolean) from public, anon, authenticated;
grant execute on function public.admin_set_place_disabled(text, text, boolean) to anon, authenticated;

