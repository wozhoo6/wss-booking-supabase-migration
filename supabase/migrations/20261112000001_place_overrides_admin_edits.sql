-- Manual (admin) edits for places, kept apart from the scraped data.
--
-- Rule: Google/scraped data ALWAYS wins. A manual value is only a fallback, used
-- when the scraped value is empty:
--   * description / website / phone: manual used only if no scraped value exists
--   * hours: manual used only if Google has no clinic_hours rows for the place
--   * doctors: manual doctors are added to the scraped ones; a wrong scraped link
--     can be hidden for a place
-- Manual data is keyed by place_id (not address_id), so imports, re-imports and
-- reverts never touch it. If Google later gains a value it takes over automatically
-- and the manual one stays stored, dormant.
--
-- Admin access is the existing shared admin key (private.require_admin). No audit log.

---------------------------------------------------------------------------
-- Tables
---------------------------------------------------------------------------
create table public.place_overrides (
  place_id    text primary key check (place_id <> ''),
  description text check (description is null or length(description) <= 2000),
  website     text check (website is null or (length(website) <= 500 and website ~* '^https?://[^[:space:]]+$')),
  phone       text check (phone is null or phone ~ '^[0-9+()xX. -]{7,30}$'),
  hours_text  text,  -- generated from place_hours_overrides when hours are saved
  updated_at  timestamptz not null default now()
);

create table public.place_hours_overrides (
  hour_id           integer generated always as identity primary key,
  place_id          text    not null check (place_id <> ''),
  day_of_week       integer not null check (day_of_week between 0 and 6),        -- 0 = Sunday
  open_time         time    not null,
  close_day_of_week integer not null check (close_day_of_week between 0 and 6),
  close_time        time    not null,
  unique (place_id, day_of_week, open_time, close_day_of_week, close_time)
);

create index place_hours_overrides_place_id_idx on public.place_hours_overrides (place_id);

-- Doctors added by hand. NPI is optional; no row is created in public.dermatologists.
create table public.place_dermatologist_links (
  link_id    integer generated always as identity primary key,
  place_id   text not null check (place_id <> ''),
  name       text not null check (btrim(name) <> '' and length(name) <= 200),
  npi        text check (npi is null or npi ~ '^\d{10}$'),
  created_at timestamptz not null default now()
);

create unique index place_dermatologist_links_npi_uq
  on public.place_dermatologist_links (place_id, npi) where npi is not null;
create unique index place_dermatologist_links_name_uq
  on public.place_dermatologist_links (place_id, lower(btrim(name))) where npi is null;

-- Scraped doctor links an admin has hidden for a place.
create table public.place_dermatologist_hidden (
  place_id text not null check (place_id <> ''),
  npi      text not null,
  primary key (place_id, npi)
);

alter table public.place_overrides            enable row level security;
alter table public.place_hours_overrides      enable row level security;
alter table public.place_dermatologist_links  enable row level security;
alter table public.place_dermatologist_hidden enable row level security;

revoke all on public.place_overrides, public.place_hours_overrides,
              public.place_dermatologist_links, public.place_dermatologist_hidden
  from anon, authenticated;

---------------------------------------------------------------------------
-- Helpers (private schema)
---------------------------------------------------------------------------
create or replace function private.fmt_time(p_time time)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p_time = time '24:00' then '12:00 AM'
              else to_char(p_time, 'FMHH12:MI AM') end;
$$;

-- "Monday: 8:00 AM – 5:00 PM" lines (Monday first, like Google) for a place's manual
-- hours. NULL when the place has no manual hours.
create or replace function private.hours_text_from_periods(p_place_id text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when not exists (select 1 from public.place_hours_overrides where place_id = p_place_id) then null
    else (
      select string_agg(d.day_name || ': ' || coalesce(x.txt, 'Closed'), E'\n' order by d.ord)
      from (values (1, 1, 'Monday'), (2, 2, 'Tuesday'), (3, 3, 'Wednesday'), (4, 4, 'Thursday'),
                   (5, 5, 'Friday'), (6, 6, 'Saturday'), (7, 0, 'Sunday')) as d(ord, day_num, day_name)
      left join lateral (
        select case
                 when count(*) = 1 and min(o.open_time) = time '00:00' and min(o.close_time) = time '24:00'
                   then 'Open 24 hours'
                 else string_agg(private.fmt_time(o.open_time) || ' ' || chr(8211) || ' ' || private.fmt_time(o.close_time),
                                 ', ' order by o.open_time)
               end as txt
        from public.place_hours_overrides o
        where o.place_id = p_place_id and o.day_of_week = d.day_num
      ) x on true)
  end;
$$;

-- Opening hours object for the API. Google's rows (for the chosen address) win;
-- manual rows are used only when Google has none.
create or replace function private.opening_hours_json(p_address_id integer, p_place_id text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with src as (
    select h.day_of_week, h.open_time, h.close_day_of_week, h.close_time
    from public.clinic_hours h
    where h.address_id = p_address_id
    union all
    select o.day_of_week, o.open_time, o.close_day_of_week, o.close_time
    from public.place_hours_overrides o
    where o.place_id = p_place_id
      and not exists (select 1 from public.clinic_hours h2 where h2.address_id = p_address_id)
  )
  select case when exists (select 1 from src) then (
    select jsonb_object_agg(
             d.day_key,
             coalesce((
               select jsonb_agg(
                        jsonb_build_object('open',  left(s.open_time::text, 5),
                                           'close', left(s.close_time::text, 5))
                        || case when s.close_day_of_week <> s.day_of_week
                                then jsonb_build_object(
                                       'close_day',
                                       (array['Sun','Mon','Tue','Wed','Thu','Fri','Sat'])[s.close_day_of_week + 1])
                                else '{}'::jsonb end
                        order by s.open_time, s.close_day_of_week, s.close_time)
               from src s
               where s.day_of_week = d.day_num
             ), '[]'::jsonb))
    from (values (0, 'Sun'), (1, 'Mon'), (2, 'Tue'), (3, 'Wed'),
                 (4, 'Thu'), (5, 'Fri'), (6, 'Sat')) as d(day_num, day_key))
  else '{}'::jsonb end;
$$;

---------------------------------------------------------------------------
-- Doctors per place: scraped links (minus hidden ones) plus manual doctors.
-- Columns 1-4 are unchanged; source and link_id are appended.
-- A manual doctor whose NPI is already a visible scraped link is not repeated.
---------------------------------------------------------------------------
create or replace view public.place_dermatologists
with (security_invoker = true)
as
with scraped as (
  select distinct on (ca.place_id, d.npi)
    ca.place_id,
    d.npi,
    d.name,
    a.confidence
  from public.clinic_addresses ca
  join public.assignments a    using (clinic_id)
  join public.dermatologists d using (npi)
  where not exists (
    select 1 from public.place_dermatologist_hidden h
    where h.place_id = ca.place_id and h.npi = d.npi)
  order by ca.place_id, d.npi, (a.confidence = 'high') desc
)
select s.place_id, s.npi, s.name, s.confidence,
       'scraped'::text as source, null::integer as link_id
from scraped s
union all
select l.place_id, l.npi, l.name, 'high'::text, 'manual'::text, l.link_id
from public.place_dermatologist_links l
where l.npi is null
   or not exists (select 1 from scraped s where s.place_id = l.place_id and s.npi = l.npi);

---------------------------------------------------------------------------
-- place_json: scraped value first, manual value as fallback.
-- New field hours_source: 'google' | 'manual' | null.
-- Same shape as before otherwise (see migration 20261111000001 for opening_hours).
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
  from public.places p
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
-- log_redirect: same as migration 09; a manual website is used only when Google has none.
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

  select p.business_status,
         coalesce(nullif(btrim(p.website), ''), nullif(btrim(po.website), ''))
  into v_status, v_url
  from public.places p
  left join public.place_overrides po on po.place_id = p.place_id
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
-- get_place: same as migration 09; doctors now include manual ones. A manual doctor
-- without an NPI gets the id 'manual-<link_id>'.
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
               'id', coalesce(d.npi, 'manual-' || d.link_id), 'name', d.name,
               'specialization', null, 'profile_bio', null, 'photo_url', null)
             order by d.name, d.npi, d.link_id)
      from public.place_dermatologists d
      where d.place_id = p_place_id and d.confidence = 'high'), '[]'::jsonb));
end;
$$;

---------------------------------------------------------------------------
-- admin_get_place: adds scraped vs manual values, doctor source, hidden doctors.
-- The top-level fields (description, website, phone, hours...) are the values in effect.
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
      'website', (select nullif(btrim(p.website), '') from public.places p where p.place_id = p_place_id),
      'phone',   (select nullif(btrim(p.phone), '')   from public.places p where p.place_id = p_place_id),
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
-- Places list with "what is missing" flags, judged on the values in effect
-- (scraped or manual). p_missing filters to places lacking one of:
-- description | website | phone | hours | dermatologists | any
-- ('any' = description, website, hours or dermatologists).
---------------------------------------------------------------------------
create or replace function private.place_listing(p_search text, p_missing text)
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
  has_dermatologists boolean
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
              where d.place_id = p.place_id and d.confidence = 'high') as has_dermatologists
    from public.places p
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

-- Replaces admin_list_places: new optional last argument p_missing; old 4-argument
-- calls keep working through the default.
drop function public.admin_list_places(text, text, integer, integer);

create function public.admin_list_places(
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

  select count(*) into v_total from private.place_listing(v_q, v_missing);

  select coalesce(jsonb_agg(x.obj order by x.pr asc nulls last, x.nm, x.id), '[]'::jsonb)
  into v_clinics
  from (
    select f.place_id as id, f.priority_rank as pr, lower(f.place_name) as nm,
           jsonb_build_object(
             'id', f.place_id, 'name', f.place_name, 'city', f.city, 'zip', f.zip,
             'business_status', f.business_status, 'priority_rank', f.priority_rank,
             'referral_count', (select count(*) from public.referral_interactions ri
                                where ri.place_id = f.place_id),
             'has_description', f.has_description, 'has_website', f.has_website,
             'has_phone', f.has_phone, 'has_hours', f.has_hours,
             'has_dermatologists', f.has_dermatologists) as obj
    from private.place_listing(v_q, v_missing) f
    order by f.priority_rank asc nulls last, lower(f.place_name), f.place_id
    limit p_limit offset p_offset
  ) x;

  return jsonb_build_object('total', v_total, 'clinics', v_clinics);
end;
$$;

---------------------------------------------------------------------------
-- Admin edits. Each returns the refreshed admin_get_place object.
---------------------------------------------------------------------------

-- p_patch: {"description": "...", "website": "https://...", "phone": "..."}; only the
-- keys present are changed; null or '' clears that manual value.
create or replace function public.admin_update_place(p_admin_key text, p_place_id text, p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key   text;
  v_desc  text;
  v_web   text;
  v_phone text;
begin
  perform private.require_admin(p_admin_key);

  if not exists (select 1 from public.places where place_id = p_place_id) then
    raise exception 'unknown place_id: %', p_place_id using errcode = 'P0002';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'patch must be a JSON object' using errcode = '22023';
  end if;

  for v_key in select jsonb_object_keys(p_patch) loop
    if v_key not in ('description', 'website', 'phone') then
      raise exception 'unknown field: % (allowed: description, website, phone)', v_key using errcode = '22023';
    end if;
    if jsonb_typeof(p_patch -> v_key) not in ('string', 'null') then
      raise exception '% must be text or null', v_key using errcode = '22023';
    end if;
  end loop;

  v_desc  := nullif(btrim(p_patch ->> 'description'), '');
  v_web   := nullif(btrim(p_patch ->> 'website'), '');
  v_phone := nullif(btrim(p_patch ->> 'phone'), '');

  if length(v_desc) > 2000 then
    raise exception 'description must be at most 2000 characters' using errcode = '22023';
  end if;
  if v_web is not null and (length(v_web) > 500 or v_web !~* '^https?://[^[:space:]]+$') then
    raise exception 'website must be an http(s) URL of at most 500 characters' using errcode = '22023';
  end if;
  if v_phone is not null and v_phone !~ '^[0-9+()xX. -]{7,30}$' then
    raise exception 'phone must be 7-30 characters: digits, spaces and + ( ) - . x' using errcode = '22023';
  end if;

  insert into public.place_overrides as t (place_id, description, website, phone)
  values (p_place_id, v_desc, v_web, v_phone)
  on conflict (place_id) do update set
    description = case when p_patch -> 'description' is not null then excluded.description else t.description end,
    website     = case when p_patch -> 'website'     is not null then excluded.website     else t.website     end,
    phone       = case when p_patch -> 'phone'       is not null then excluded.phone       else t.phone       end,
    updated_at  = now();

  delete from public.place_overrides
  where place_id = p_place_id
    and description is null and website is null and phone is null and hours_text is null;

  return public.admin_get_place(p_admin_key, p_place_id);
end;
$$;

-- p_periods: [{"day_of_week": 1, "open_time": "08:00", "close_time": "17:00"}, ...]
-- close_day_of_week is optional (defaults to day_of_week; use the next day for periods
-- running past midnight). 0 = Sunday. A closed day has no entry; a lunch break is two
-- entries. An empty array or null removes the manual hours. Replaces the whole set.
create or replace function public.admin_set_place_hours(p_admin_key text, p_place_id text, p_periods jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n    integer;
  v_text text;
begin
  perform private.require_admin(p_admin_key);

  if not exists (select 1 from public.places where place_id = p_place_id) then
    raise exception 'unknown place_id: %', p_place_id using errcode = 'P0002';
  end if;

  if p_periods is null or p_periods = 'null'::jsonb then
    p_periods := '[]'::jsonb;
  end if;
  if jsonb_typeof(p_periods) <> 'array' then
    raise exception 'periods must be a JSON array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_periods) > 70 then
    raise exception 'at most 70 periods' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_periods) e where jsonb_typeof(e) <> 'object') then
    raise exception 'each period must be an object' using errcode = '22023';
  end if;

  select count(*) into v_n
  from jsonb_array_elements(p_periods) e
  where not coalesce(
    (e ->> 'day_of_week') ~ '^[0-6]$'
    and (e ->> 'open_time')  ~ '^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$'
    and (e ->> 'close_time') ~ '^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$'
    and coalesce(e ->> 'close_day_of_week', e ->> 'day_of_week') ~ '^[0-6]$', false);
  if v_n > 0 then
    raise exception '% period(s) have an invalid day (0-6) or time (HH:MM, 24-hour)', v_n using errcode = '22023';
  end if;

  -- Same-day periods must close after they open; otherwise they must close the next day.
  select count(*) into v_n
  from (
    select (e ->> 'day_of_week')::integer as d,
           coalesce((e ->> 'close_day_of_week')::integer, (e ->> 'day_of_week')::integer) as cd,
           (e ->> 'open_time')::time as ot,
           (e ->> 'close_time')::time as ct
    from jsonb_array_elements(p_periods) e) x
  where (x.cd = x.d and x.ct <= x.ot)
     or (x.cd <> x.d and x.cd <> (x.d + 1) % 7);
  if v_n > 0 then
    raise exception '% period(s) close before they open or on the wrong day', v_n using errcode = '22023';
  end if;

  delete from public.place_hours_overrides where place_id = p_place_id;

  insert into public.place_hours_overrides
    (place_id, day_of_week, open_time, close_day_of_week, close_time)
  select p_place_id,
         (e ->> 'day_of_week')::integer,
         (e ->> 'open_time')::time,
         coalesce((e ->> 'close_day_of_week')::integer, (e ->> 'day_of_week')::integer),
         (e ->> 'close_time')::time
  from jsonb_array_elements(p_periods) e
  on conflict do nothing;

  v_text := private.hours_text_from_periods(p_place_id);

  insert into public.place_overrides as t (place_id, hours_text)
  values (p_place_id, v_text)
  on conflict (place_id) do update set hours_text = excluded.hours_text, updated_at = now();

  delete from public.place_overrides
  where place_id = p_place_id
    and description is null and website is null and phone is null and hours_text is null;

  return public.admin_get_place(p_admin_key, p_place_id);
end;
$$;

-- Adds a doctor by name; p_npi (10 digits) is optional. Nothing is written to
-- public.dermatologists. Adding the same doctor again is a no-op.
create or replace function public.admin_link_dermatologist(
  p_admin_key text,
  p_place_id  text,
  p_name      text,
  p_npi       text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := btrim(p_name);
  v_npi  text := nullif(btrim(p_npi), '');
begin
  perform private.require_admin(p_admin_key);

  if not exists (select 1 from public.places where place_id = p_place_id) then
    raise exception 'unknown place_id: %', p_place_id using errcode = 'P0002';
  end if;
  if v_name is null or v_name = '' or length(v_name) > 200 then
    raise exception 'name is required and must be at most 200 characters' using errcode = '22023';
  end if;
  if v_npi is not null and v_npi !~ '^\d{10}$' then
    raise exception 'npi must be 10 digits' using errcode = '22023';
  end if;

  insert into public.place_dermatologist_links (place_id, name, npi)
  values (p_place_id, v_name, v_npi)
  on conflict do nothing;

  return public.admin_get_place(p_admin_key, p_place_id);
end;
$$;

-- Removes a doctor from a place. Pass p_link_id for a manual doctor, or p_npi:
-- a manual link with that NPI is deleted and a scraped link with that NPI is hidden.
create or replace function public.admin_unlink_dermatologist(
  p_admin_key text,
  p_place_id  text,
  p_npi       text default null,
  p_link_id   integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_npi     text := nullif(btrim(p_npi), '');
  v_removed integer := 0;
  v_n       integer;
begin
  perform private.require_admin(p_admin_key);

  if (v_npi is null) = (p_link_id is null) then
    raise exception 'pass exactly one of npi or link_id' using errcode = '22023';
  end if;

  if p_link_id is not null then
    delete from public.place_dermatologist_links
    where link_id = p_link_id and place_id = p_place_id;
    get diagnostics v_removed = row_count;
  else
    delete from public.place_dermatologist_links
    where place_id = p_place_id and npi = v_npi;
    get diagnostics v_removed = row_count;

    insert into public.place_dermatologist_hidden (place_id, npi)
    select p_place_id, v_npi
    where exists (
      select 1
      from public.clinic_addresses ca
      join public.assignments a using (clinic_id)
      where ca.place_id = p_place_id and a.npi = v_npi)
    on conflict do nothing;
    get diagnostics v_n = row_count;
    v_removed := v_removed + v_n;
  end if;

  if v_removed = 0 then
    raise exception 'no such doctor link on this place' using errcode = 'P0002';
  end if;

  return public.admin_get_place(p_admin_key, p_place_id);
end;
$$;

-- Shows a hidden scraped doctor link again.
create or replace function public.admin_unhide_dermatologist(p_admin_key text, p_place_id text, p_npi text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_admin(p_admin_key);

  delete from public.place_dermatologist_hidden
  where place_id = p_place_id and npi = btrim(p_npi);
  if not found then
    raise exception 'that doctor is not hidden on this place' using errcode = 'P0002';
  end if;

  return public.admin_get_place(p_admin_key, p_place_id);
end;
$$;

---------------------------------------------------------------------------
-- Grants: anon can call the admin functions; the admin key check is inside each one.
---------------------------------------------------------------------------
revoke all on function private.fmt_time(time)                           from public, anon, authenticated;
revoke all on function private.hours_text_from_periods(text)            from public, anon, authenticated;
revoke all on function private.opening_hours_json(integer, text)        from public, anon, authenticated;
revoke all on function private.place_listing(text, text)                from public, anon, authenticated;

revoke all on function public.admin_list_places(text, text, integer, integer, text) from public, anon, authenticated;
revoke all on function public.admin_update_place(text, text, jsonb)                 from public, anon, authenticated;
revoke all on function public.admin_set_place_hours(text, text, jsonb)              from public, anon, authenticated;
revoke all on function public.admin_link_dermatologist(text, text, text, text)      from public, anon, authenticated;
revoke all on function public.admin_unlink_dermatologist(text, text, text, integer) from public, anon, authenticated;
revoke all on function public.admin_unhide_dermatologist(text, text, text)          from public, anon, authenticated;

grant execute on function public.admin_list_places(text, text, integer, integer, text) to anon, authenticated;
grant execute on function public.admin_update_place(text, text, jsonb)                 to anon, authenticated;
grant execute on function public.admin_set_place_hours(text, text, jsonb)              to anon, authenticated;
grant execute on function public.admin_link_dermatologist(text, text, text, text)      to anon, authenticated;
grant execute on function public.admin_unlink_dermatologist(text, text, text, integer) to anon, authenticated;
grant execute on function public.admin_unhide_dermatologist(text, text, text)          to anon, authenticated;
