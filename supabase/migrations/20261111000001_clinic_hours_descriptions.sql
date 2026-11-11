-- Opening hours and website descriptions for Google places.
--
-- Mirrors the derm-scraper additions:
--   clinic_addresses.hours_text / hours_fetched_at / description / description_fetched_at
--   clinic_hours (one row per open period)
--
-- Additive: tables and columns are added, import_batch() and the place JSON
-- functions are replaced. Earlier migrations are untouched.
--
-- Re-import rule for these fields ("newer fetch wins"), unlike the fill-blanks-only
-- rule used for the rest of the data:
--   * hours_text, hours_fetched_at, business_status and the clinic_hours rows are
--     replaced only when the incoming hours_fetched_at is newer than the stored one
--     (a stored NULL counts as oldest). business_status is refreshed by the scraper's
--     hours fetch, so it follows hours_fetched_at.
--   * description / description_fetched_at are replaced only when the incoming
--     description_fetched_at is newer. An empty incoming description never erases a
--     stored one (a blocked website request must not wipe a good description).

---------------------------------------------------------------------------
-- Tables and columns
---------------------------------------------------------------------------
alter table public.clinic_addresses
  add column hours_text              text,  -- one line per day: "Monday: 8:00 AM – 5:00 PM"; NULL = Google has none
  add column hours_fetched_at        date,  -- NULL = hours never fetched
  add column description             text,  -- website meta description; NULL = none / blocked
  add column description_fetched_at  date;  -- NULL = website never checked

-- One row per open period. A closed day has no row; a lunch break is two rows;
-- 24 hours is 00:00-24:00 on all seven days. Postgres `time` accepts 24:00.
create table public.clinic_hours (
  hour_id           integer generated always as identity primary key,
  address_id        integer not null references public.clinic_addresses (address_id) on delete cascade,
  day_of_week       integer not null check (day_of_week between 0 and 6),        -- 0 = Sunday
  open_time         time    not null,
  close_day_of_week integer not null check (close_day_of_week between 0 and 6),  -- = day_of_week unless past midnight
  close_time        time    not null,
  fetched_at        date    not null,
  unique (address_id, day_of_week, open_time, close_day_of_week, close_time)
);

create index clinic_hours_address_id_idx on public.clinic_hours (address_id);

alter table public.clinic_hours enable row level security;
revoke all on public.clinic_hours from anon, authenticated;

alter table public.import_batches
  add column hours_inserted integer not null default 0,
  add column hours_deleted  integer not null default 0;

---------------------------------------------------------------------------
-- Staging
---------------------------------------------------------------------------
alter table staging.stg_clinic_addresses
  add column hours_text             text,
  add column hours_fetched_at       text,
  add column description            text,
  add column description_fetched_at text;

create table staging.stg_clinic_hours (
  batch_id          integer not null references public.import_batches (batch_id) on delete cascade,
  src_hour_id       integer not null,
  src_address_id    integer not null,
  day_of_week       integer not null,
  open_time         text    not null,
  close_day_of_week integer not null,
  close_time        text    not null,
  fetched_at        text    not null,
  primary key (batch_id, src_hour_id)
);

---------------------------------------------------------------------------
-- import_batch: same as migration 07, plus hours and descriptions
---------------------------------------------------------------------------
create or replace function public.import_batch(p_batch_id integer, p_dry_run boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_region   text;
  v_problems text[] := '{}';
  v_n        integer;
  c_ins integer := 0; c_upd integer := 0;
  a_ins integer := 0; a_upd integer := 0;
  d_ins integer := 0; d_upd integer := 0;
  s_ins integer := 0; v_skipped integer := 0;
  h_ins integer := 0; h_del integer := 0;
  v_result jsonb;
begin
  select region into v_region
  from public.import_batches
  where batch_id = p_batch_id and status = 'pending'
  for update;

  if v_region is null then
    raise exception 'import_batch: batch % does not exist or is not pending', p_batch_id;
  end if;

  ---------------------------------------------------------------------------
  -- Validation (any problem aborts the whole call)
  ---------------------------------------------------------------------------
  select count(*) into v_n from staging.stg_clinic_addresses
  where batch_id = p_batch_id and (lat is null or lng is null);
  if v_n > 0 then v_problems := v_problems || format('%s address rows without lat/lng', v_n); end if;

  select count(*) into v_n from staging.stg_clinic_addresses
  where batch_id = p_batch_id and coalesce(place_id, '') = '';
  if v_n > 0 then v_problems := v_problems || format('%s address rows without place_id', v_n); end if;

  select count(*) into v_n from (
    select 1 from staging.stg_clinics where batch_id = p_batch_id
    group by npi, address1, address2, zip having count(*) > 1) x;
  if v_n > 0 then v_problems := v_problems || format('%s duplicate clinic natural keys', v_n); end if;

  select count(*) into v_n from (
    select 1 from staging.stg_clinic_addresses where batch_id = p_batch_id
    group by src_clinic_id, place_id having count(*) > 1) x;
  if v_n > 0 then v_problems := v_problems || format('%s duplicate (clinic, place_id) rows', v_n); end if;

  select count(*) into v_n from staging.stg_clinic_addresses sa
  where sa.batch_id = p_batch_id and not exists (
    select 1 from staging.stg_clinics sc
    where sc.batch_id = p_batch_id and sc.src_clinic_id = sa.src_clinic_id);
  if v_n > 0 then v_problems := v_problems || format('%s address rows pointing at a missing clinic', v_n); end if;

  select count(*) into v_n from staging.stg_assignments sg
  where sg.batch_id = p_batch_id and (
    not exists (select 1 from staging.stg_clinics sc
                where sc.batch_id = p_batch_id and sc.src_clinic_id = sg.src_clinic_id)
    or not exists (select 1 from staging.stg_dermatologists sd
                   where sd.batch_id = p_batch_id and sd.npi = sg.npi));
  if v_n > 0 then v_problems := v_problems || format('%s assignments pointing at a missing clinic or doctor', v_n); end if;

  select count(*) into v_n from staging.stg_clinics
  where batch_id = p_batch_id and state <> v_region;
  if v_n > 0 then v_problems := v_problems || format('%s clinics outside region %s', v_n, v_region); end if;

  -- Hours and descriptions
  select count(*) into v_n from staging.stg_clinic_addresses
  where batch_id = p_batch_id and (
    (nullif(hours_fetched_at, '')       is not null and hours_fetched_at       !~ '^\d{4}-\d{2}-\d{2}$')
    or (nullif(description_fetched_at, '') is not null and description_fetched_at !~ '^\d{4}-\d{2}-\d{2}$'));
  if v_n > 0 then v_problems := v_problems || format('%s address rows with a malformed hours/description fetch date', v_n); end if;

  select count(*) into v_n from staging.stg_clinic_hours sh
  where sh.batch_id = p_batch_id and not exists (
    select 1 from staging.stg_clinic_addresses sa
    where sa.batch_id = p_batch_id and sa.src_address_id = sh.src_address_id);
  if v_n > 0 then v_problems := v_problems || format('%s hour rows pointing at a missing address', v_n); end if;

  select count(*) into v_n from staging.stg_clinic_hours sh
  where sh.batch_id = p_batch_id and (
    sh.day_of_week not between 0 and 6
    or sh.close_day_of_week not between 0 and 6
    or sh.open_time  !~ '^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$'
    or sh.close_time !~ '^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$'
    or sh.fetched_at !~ '^\d{4}-\d{2}-\d{2}$');
  if v_n > 0 then v_problems := v_problems || format('%s hour rows with an invalid day, time or date', v_n); end if;

  select count(*) into v_n from staging.stg_clinic_hours sh
  join staging.stg_clinic_addresses sa
    on sa.batch_id = sh.batch_id and sa.src_address_id = sh.src_address_id
  where sh.batch_id = p_batch_id and nullif(sa.hours_fetched_at, '') is null;
  if v_n > 0 then v_problems := v_problems || format('%s hour rows for addresses with no hours_fetched_at', v_n); end if;

  if cardinality(v_problems) > 0 then
    raise exception 'import_batch % failed validation: %', p_batch_id, array_to_string(v_problems, '; ');
  end if;

  select count(*) into v_skipped from staging.stg_clinics sc
  where sc.batch_id = p_batch_id and not exists (
    select 1 from staging.stg_clinic_addresses sa
    where sa.batch_id = p_batch_id and sa.src_clinic_id = sc.src_clinic_id);

  ---------------------------------------------------------------------------
  -- Load (inside a sub-block so a dry run can roll it back)
  ---------------------------------------------------------------------------
  begin
    -- Clinics with at least one Google row.
    with up as (
      insert into public.clinics as t
        (npi, name, address1, address2, city, state, zip, phone, first_batch_id, last_batch_id)
      select sc.npi, sc.name, sc.address1, sc.address2, sc.city, sc.state, sc.zip, sc.phone,
             p_batch_id, p_batch_id
      from staging.stg_clinics sc
      where sc.batch_id = p_batch_id and exists (
        select 1 from staging.stg_clinic_addresses sa
        where sa.batch_id = p_batch_id and sa.src_clinic_id = sc.src_clinic_id)
      on conflict (npi, address1, address2, zip) do update set
        name          = coalesce(nullif(t.name, ''),  excluded.name),
        city          = coalesce(nullif(t.city, ''),  excluded.city),
        state         = coalesce(nullif(t.state, ''), excluded.state),
        phone         = coalesce(nullif(t.phone, ''), excluded.phone),
        last_batch_id = excluded.last_batch_id
      returning (xmax = 0) as inserted
    )
    select count(*) filter (where inserted), count(*) filter (where not inserted)
    into c_ins, c_upd from up;

    -- Hours of existing addresses whose incoming hours are newer are removed here;
    -- the fresh set is inserted after the address upsert below.
    delete from public.clinic_hours h
    using public.clinic_addresses ca
    join public.clinics c on c.clinic_id = ca.clinic_id
    join staging.stg_clinics sc
      on sc.batch_id = p_batch_id
     and (c.npi, c.address1, c.address2, c.zip) = (sc.npi, sc.address1, sc.address2, sc.zip)
    join staging.stg_clinic_addresses sa
      on sa.batch_id = sc.batch_id and sa.src_clinic_id = sc.src_clinic_id and sa.place_id = ca.place_id
    where h.address_id = ca.address_id
      and nullif(sa.hours_fetched_at, '')::date > coalesce(ca.hours_fetched_at, date '-infinity');
    get diagnostics h_del = row_count;

    -- Google places, mapped to the Postgres clinic_id through the natural key.
    with up as (
      insert into public.clinic_addresses as t
        (clinic_id, place_id, place_name, address, lat, lng, phone, website, rating,
         review_count, business_status, result_rank, matches_registered, search_query,
         searched_at, hours_text, hours_fetched_at, description, description_fetched_at,
         name_match, first_batch_id, last_batch_id)
      select c.clinic_id, sa.place_id, sa.place_name, sa.address, sa.lat, sa.lng, sa.phone,
             sa.website, sa.rating, sa.review_count, sa.business_status, sa.result_rank,
             sa.matches_registered, sa.search_query, sa.searched_at::timestamptz,
             nullif(sa.hours_text, ''), nullif(sa.hours_fetched_at, '')::date,
             nullif(sa.description, ''), nullif(sa.description_fetched_at, '')::date,
             sa.name_match, p_batch_id, p_batch_id
      from staging.stg_clinic_addresses sa
      join staging.stg_clinics sc
        on sc.batch_id = sa.batch_id and sc.src_clinic_id = sa.src_clinic_id
      join public.clinics c
        on (c.npi, c.address1, c.address2, c.zip) = (sc.npi, sc.address1, sc.address2, sc.zip)
      where sa.batch_id = p_batch_id
      on conflict (clinic_id, place_id) do update set
        place_name      = coalesce(nullif(t.place_name, ''), excluded.place_name),
        address         = coalesce(nullif(t.address, ''),    excluded.address),
        phone           = coalesce(nullif(t.phone, ''),      excluded.phone),
        website         = coalesce(nullif(t.website, ''),    excluded.website),
        rating          = coalesce(t.rating,          excluded.rating),
        review_count    = coalesce(t.review_count,    excluded.review_count),
        -- Newer hours fetch wins (the status is refreshed by the same fetch).
        business_status = case
                            when excluded.hours_fetched_at > coalesce(t.hours_fetched_at, date '-infinity')
                              then coalesce(nullif(excluded.business_status, ''), t.business_status)
                            else coalesce(nullif(t.business_status, ''), excluded.business_status)
                          end,
        hours_text      = case
                            when excluded.hours_fetched_at > coalesce(t.hours_fetched_at, date '-infinity')
                              then excluded.hours_text
                            else t.hours_text
                          end,
        hours_fetched_at = case
                            when excluded.hours_fetched_at > coalesce(t.hours_fetched_at, date '-infinity')
                              then excluded.hours_fetched_at
                            else t.hours_fetched_at
                          end,
        -- Newer description check wins, but an empty result never erases a value.
        description     = case
                            when excluded.description_fetched_at > coalesce(t.description_fetched_at, date '-infinity')
                              then coalesce(nullif(excluded.description, ''), t.description)
                            else t.description
                          end,
        description_fetched_at = case
                            when excluded.description_fetched_at > coalesce(t.description_fetched_at, date '-infinity')
                              then excluded.description_fetched_at
                            else t.description_fetched_at
                          end,
        name_match      = coalesce(t.name_match,      excluded.name_match),
        last_batch_id   = excluded.last_batch_id
      returning (xmax = 0) as inserted
    )
    select count(*) filter (where inserted), count(*) filter (where not inserted)
    into a_ins, a_upd from up;

    -- Open periods. Only addresses whose stored hours_fetched_at now equals the
    -- incoming one are written (new addresses, and those just refreshed above), so a
    -- stale file never overwrites newer hours and re-importing the same file adds nothing.
    insert into public.clinic_hours
      (address_id, day_of_week, open_time, close_day_of_week, close_time, fetched_at)
    select ca.address_id, sh.day_of_week, sh.open_time::time, sh.close_day_of_week,
           sh.close_time::time, sh.fetched_at::date
    from staging.stg_clinic_hours sh
    join staging.stg_clinic_addresses sa
      on sa.batch_id = sh.batch_id and sa.src_address_id = sh.src_address_id
    join staging.stg_clinics sc
      on sc.batch_id = sa.batch_id and sc.src_clinic_id = sa.src_clinic_id
    join public.clinics c
      on (c.npi, c.address1, c.address2, c.zip) = (sc.npi, sc.address1, sc.address2, sc.zip)
    join public.clinic_addresses ca
      on ca.clinic_id = c.clinic_id and ca.place_id = sa.place_id
    where sh.batch_id = p_batch_id
      and nullif(sa.hours_fetched_at, '')::date = ca.hours_fetched_at
    on conflict (address_id, day_of_week, open_time, close_day_of_week, close_time) do nothing;
    get diagnostics h_ins = row_count;

    -- Doctors linked to an imported clinic.
    with up as (
      insert into public.dermatologists as t
        (npi, name, address1, address2, city, state, zip, phone, first_seen, last_seen,
         first_batch_id, last_batch_id)
      select sd.npi, sd.name, sd.address1, sd.address2, sd.city, sd.state, sd.zip, sd.phone,
             sd.first_seen::date, sd.last_seen::date, p_batch_id, p_batch_id
      from staging.stg_dermatologists sd
      where sd.batch_id = p_batch_id and exists (
        select 1
        from staging.stg_assignments sg
        join staging.stg_clinic_addresses sa
          on sa.batch_id = sg.batch_id and sa.src_clinic_id = sg.src_clinic_id
        where sg.batch_id = p_batch_id and sg.npi = sd.npi)
      on conflict (npi) do update set
        name          = coalesce(nullif(t.name, ''),     excluded.name),
        address1      = coalesce(nullif(t.address1, ''), excluded.address1),
        address2      = coalesce(nullif(t.address2, ''), excluded.address2),
        city          = coalesce(nullif(t.city, ''),     excluded.city),
        state         = coalesce(nullif(t.state, ''),    excluded.state),
        zip           = coalesce(nullif(t.zip, ''),      excluded.zip),
        phone         = coalesce(nullif(t.phone, ''),    excluded.phone),
        first_seen    = least(t.first_seen, excluded.first_seen),
        last_seen     = greatest(t.last_seen, excluded.last_seen),
        last_batch_id = excluded.last_batch_id
      returning (xmax = 0) as inserted
    )
    select count(*) filter (where inserted), count(*) filter (where not inserted)
    into d_ins, d_upd from up;

    -- Links (existing links are left exactly as they are).
    insert into public.assignments (npi, clinic_id, confidence, derm_name, clinic_name, first_batch_id)
    select sg.npi, c.clinic_id, sg.confidence, sg.derm_name, sg.clinic_name, p_batch_id
    from staging.stg_assignments sg
    join staging.stg_clinics sc
      on sc.batch_id = sg.batch_id and sc.src_clinic_id = sg.src_clinic_id
    join public.clinics c
      on (c.npi, c.address1, c.address2, c.zip) = (sc.npi, sc.address1, sc.address2, sc.zip)
    join public.dermatologists d on d.npi = sg.npi
    where sg.batch_id = p_batch_id
    on conflict (npi, clinic_id) do nothing;
    get diagnostics s_ins = row_count;

    if p_dry_run then
      raise exception using errcode = 'P0D01', message = 'dry run rollback';
    end if;
  exception
    when sqlstate 'P0D01' then
      null;  -- loaded rows are rolled back; the counts in the variables are kept
  end;

  update public.import_batches set
    status                  = case when p_dry_run then 'dry_run' else 'committed' end,
    clinics_inserted        = c_ins, clinics_updated        = c_upd,
    addresses_inserted      = a_ins, addresses_updated      = a_upd,
    dermatologists_inserted = d_ins, dermatologists_updated = d_upd,
    assignments_inserted    = s_ins, skipped_no_google      = v_skipped,
    hours_inserted          = h_ins, hours_deleted          = h_del,
    imported_at             = now()
  where batch_id = p_batch_id;

  delete from staging.stg_clinic_hours     where batch_id = p_batch_id;
  delete from staging.stg_assignments      where batch_id = p_batch_id;
  delete from staging.stg_clinic_addresses where batch_id = p_batch_id;
  delete from staging.stg_dermatologists   where batch_id = p_batch_id;
  delete from staging.stg_clinics          where batch_id = p_batch_id;

  v_result := jsonb_build_object(
    'batch_id', p_batch_id, 'dry_run', p_dry_run,
    'clinics_inserted', c_ins, 'clinics_updated', c_upd,
    'addresses_inserted', a_ins, 'addresses_updated', a_upd,
    'dermatologists_inserted', d_ins, 'dermatologists_updated', d_upd,
    'assignments_inserted', s_ins, 'skipped_no_google', v_skipped,
    'hours_inserted', h_ins, 'hours_deleted', h_del);
  return v_result;
end;
$$;

revoke execute on function public.import_batch(integer, boolean) from public, anon, authenticated;

-- revert_batch needs no code change: clinic_hours rows go with their address (cascade).
comment on function public.revert_batch(integer, boolean) is
  'Deletes rows first created by the batch (their clinic_hours cascade). Fill-blank updates and refreshed hours/description/business_status on older rows cannot be undone.';

---------------------------------------------------------------------------
-- place_json: real description and opening hours (replaces the stubs).
--
-- opening_hours is keyed Sun..Sat; each value is an array of periods, empty = closed:
--   {"Mon": [{"open": "08:00", "close": "12:00"}, {"open": "13:00", "close": "17:00"}],
--    "Fri": [{"open": "22:00", "close": "02:00", "close_day": "Sat"}], "Sun": [], ...}
-- close_day appears only when the period runs past midnight. "24:00" means end of day.
-- opening_hours is {} when Google has no hours for the place (unknown, not closed).
--
-- The same place can have several address rows (one per registered clinic that
-- found it). Hours come from the row with the newest hours fetch; the description
-- from the row with the newest non-empty description.
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
    'description', (
      select ca.description
      from public.clinic_addresses ca
      where ca.place_id = p.place_id and nullif(btrim(ca.description), '') is not null
      order by ca.description_fetched_at desc nulls last, ca.address_id
      limit 1),
    'hours_text',       hs.hours_text,
    'hours_fetched_at', hs.hours_fetched_at,
    'opening_hours', case
      when exists (select 1 from public.clinic_hours ch where ch.address_id = hs.address_id) then (
        select jsonb_object_agg(
                 d.day_key,
                 coalesce((
                   select jsonb_agg(
                            jsonb_build_object('open',  left(ch.open_time::text, 5),
                                               'close', left(ch.close_time::text, 5))
                            || case when ch.close_day_of_week <> ch.day_of_week
                                    then jsonb_build_object(
                                           'close_day',
                                           (array['Sun','Mon','Tue','Wed','Thu','Fri','Sat'])[ch.close_day_of_week + 1])
                                    else '{}'::jsonb end
                            order by ch.open_time, ch.close_day_of_week, ch.close_time)
                   from public.clinic_hours ch
                   where ch.address_id = hs.address_id and ch.day_of_week = d.day_num
                 ), '[]'::jsonb))
        from (values (0, 'Sun'), (1, 'Mon'), (2, 'Tue'), (3, 'Wed'),
                     (4, 'Thu'), (5, 'Fri'), (6, 'Sat')) as d(day_num, day_key))
      else '{}'::jsonb end,
    -- Fields the old app had but the scraped data does not.
    'services',      '[]'::jsonb,
    'booking_url',   null
  )
  from public.places p
  left join lateral (
    select ca.address_id, ca.hours_text, ca.hours_fetched_at
    from public.clinic_addresses ca
    where ca.place_id = p.place_id
    order by ca.hours_fetched_at desc nulls last, (ca.hours_text is not null) desc, ca.address_id
    limit 1
  ) hs on true
  where p.place_id = p_place_id;
$$;

---------------------------------------------------------------------------
-- admin_get_place: same as migration 10, plus the fetch dates on each address row
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
      select jsonb_agg(jsonb_build_object('id', d.npi, 'name', d.name, 'confidence', d.confidence)
             order by (d.confidence = 'high') desc, d.name, d.npi)
      from public.place_dermatologists d
      where d.place_id = p_place_id), '[]'::jsonb));
end;
$$;
