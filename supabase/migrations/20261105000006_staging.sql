-- Staging tables for batch imports. The loader script fills these from a scraper
-- SQLite file (src_* = the file's local ids), then calls public.import_batch().
-- The staging schema is not exposed through the API.
create schema if not exists staging;
revoke all on schema staging from public, anon, authenticated;

create table staging.stg_clinics (
  batch_id      integer not null references public.import_batches (batch_id) on delete cascade,
  src_clinic_id integer not null,
  npi           text not null,
  name          text not null,
  address1      text not null,
  address2      text not null default '',
  city          text not null,
  state         text not null,
  zip           text not null,
  phone         text not null default '',
  primary key (batch_id, src_clinic_id)
);

create table staging.stg_clinic_addresses (
  batch_id           integer not null references public.import_batches (batch_id) on delete cascade,
  src_address_id     integer not null,
  src_clinic_id      integer not null,
  place_id           text,
  place_name         text not null default '',
  address            text not null default '',
  lat                double precision,
  lng                double precision,
  phone              text not null default '',
  website            text not null default '',
  rating             real,
  review_count       integer,
  business_status    text,
  result_rank        integer not null,
  matches_registered integer not null,
  search_query       text not null,
  searched_at        text not null,
  name_match         boolean,  -- computed by scripts/import_batch.py
  primary key (batch_id, src_address_id)
);

create table staging.stg_dermatologists (
  batch_id   integer not null references public.import_batches (batch_id) on delete cascade,
  npi        text not null,
  name       text not null,
  address1   text not null,
  address2   text not null default '',
  city       text not null,
  state      text not null,
  zip        text not null,
  phone      text not null default '',
  first_seen text not null,
  last_seen  text not null,
  primary key (batch_id, npi)
);

create table staging.stg_assignments (
  batch_id      integer not null references public.import_batches (batch_id) on delete cascade,
  npi           text not null,
  src_clinic_id integer not null,
  confidence    text not null,
  derm_name     text not null default '',
  clinic_name   text not null default '',
  primary key (batch_id, npi, src_clinic_id)
);
