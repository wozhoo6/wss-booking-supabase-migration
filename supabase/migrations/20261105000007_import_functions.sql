-- Batch import and revert. Called by scripts/import_batch.py with a direct
-- Postgres connection (service role / postgres), never through the public API.
--
-- Re-import rule: FILL BLANKS ONLY. An existing row keeps its values; a field is
-- only written when it is currently empty ('' or NULL). Exceptions:
--   * last_batch_id is always set to the importing batch (traceability).
--   * dermatologists.first_seen keeps the earliest date and last_seen the latest.

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

    -- Google places, mapped to the Postgres clinic_id through the natural key.
    with up as (
      insert into public.clinic_addresses as t
        (clinic_id, place_id, place_name, address, lat, lng, phone, website, rating,
         review_count, business_status, result_rank, matches_registered, search_query,
         searched_at, name_match, first_batch_id, last_batch_id)
      select c.clinic_id, sa.place_id, sa.place_name, sa.address, sa.lat, sa.lng, sa.phone,
             sa.website, sa.rating, sa.review_count, sa.business_status, sa.result_rank,
             sa.matches_registered, sa.search_query, sa.searched_at::timestamptz,
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
        business_status = coalesce(nullif(t.business_status, ''), excluded.business_status),
        name_match      = coalesce(t.name_match,      excluded.name_match),
        last_batch_id   = excluded.last_batch_id
      returning (xmax = 0) as inserted
    )
    select count(*) filter (where inserted), count(*) filter (where not inserted)
    into a_ins, a_upd from up;

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
    imported_at             = now()
  where batch_id = p_batch_id;

  delete from staging.stg_assignments      where batch_id = p_batch_id;
  delete from staging.stg_clinic_addresses where batch_id = p_batch_id;
  delete from staging.stg_dermatologists   where batch_id = p_batch_id;
  delete from staging.stg_clinics          where batch_id = p_batch_id;

  v_result := jsonb_build_object(
    'batch_id', p_batch_id, 'dry_run', p_dry_run,
    'clinics_inserted', c_ins, 'clinics_updated', c_upd,
    'addresses_inserted', a_ins, 'addresses_updated', a_upd,
    'dermatologists_inserted', d_ins, 'dermatologists_updated', d_upd,
    'assignments_inserted', s_ins, 'skipped_no_google', v_skipped);
  return v_result;
end;
$$;

-- Deletes only rows first created by the batch. Refuses (unless p_force) when
-- a later batch touched those rows or when a pinned address would be removed.
-- Fill-blank updates the batch made to older rows cannot be undone.
create or replace function public.revert_batch(p_batch_id integer, p_force boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status  text;
  v_later   integer;
  v_pinned  integer;
  n_clinics integer; n_addresses integer; n_derms integer; n_links integer;
begin
  select status into v_status from public.import_batches
  where batch_id = p_batch_id for update;

  if v_status is distinct from 'committed' then
    raise exception 'revert_batch: batch % is not committed (status %)', p_batch_id, v_status;
  end if;

  select
    (select count(*) from public.clinics
       where first_batch_id = p_batch_id and last_batch_id <> p_batch_id)
  + (select count(*) from public.clinic_addresses
       where first_batch_id = p_batch_id and last_batch_id <> p_batch_id)
  + (select count(*) from public.dermatologists
       where first_batch_id = p_batch_id and last_batch_id <> p_batch_id)
  + (select count(*) from public.clinic_addresses ca
       join public.clinics c using (clinic_id)
       where c.first_batch_id = p_batch_id and ca.first_batch_id <> p_batch_id)
  into v_later;

  select count(*) into v_pinned
  from public.address_priority ap
  join public.clinic_addresses ca using (address_id)
  join public.clinics c using (clinic_id)
  where ca.first_batch_id = p_batch_id or c.first_batch_id = p_batch_id;

  if (v_later > 0 or v_pinned > 0) and not p_force then
    raise exception 'revert_batch %: % row(s) were touched by a later batch and % pinned address(es) would be deleted. Call revert_batch(%, true) to proceed anyway.',
      p_batch_id, v_later, v_pinned, p_batch_id;
  end if;

  delete from public.assignments where first_batch_id = p_batch_id;
  get diagnostics n_links = row_count;

  delete from public.clinic_addresses where first_batch_id = p_batch_id;
  get diagnostics n_addresses = row_count;

  delete from public.clinics where first_batch_id = p_batch_id;  -- cascades their remaining rows
  get diagnostics n_clinics = row_count;

  delete from public.dermatologists where first_batch_id = p_batch_id;
  get diagnostics n_derms = row_count;

  update public.import_batches set status = 'reverted' where batch_id = p_batch_id;

  return jsonb_build_object(
    'batch_id', p_batch_id, 'clinics_deleted', n_clinics,
    'addresses_deleted', n_addresses, 'dermatologists_deleted', n_derms,
    'assignments_deleted', n_links);
end;
$$;

revoke execute on function public.import_batch(integer, boolean) from public, anon, authenticated;
revoke execute on function public.revert_batch(integer, boolean) from public, anon, authenticated;
