-- Tables mirroring derm-scraper/clinics.db. Column names follow the scraper.
-- Integer ids are generated here; rows are matched across batches by natural key.

-- Registered NPI organization locations (only those with a Google Places row are imported).
create table public.clinics (
  clinic_id      integer generated always as identity primary key,
  npi            text not null,
  name           text not null,
  address1       text not null,
  address2       text not null default '',
  city           text not null,
  state          text not null,
  zip            text not null,
  phone          text not null default '',
  first_batch_id integer not null references public.import_batches (batch_id),
  last_batch_id  integer not null references public.import_batches (batch_id),
  unique (npi, address1, address2, zip)
);

create index clinics_state_idx on public.clinics (state);
create index clinics_npi_idx   on public.clinics (npi);

-- Google Places results per registered clinic. This is the public address table.
create table public.clinic_addresses (
  address_id         integer generated always as identity primary key,
  clinic_id          integer not null references public.clinics (clinic_id) on delete cascade,
  place_id           text not null check (place_id <> ''),
  place_name         text not null default '',
  address            text not null default '',
  lat                double precision not null,
  lng                double precision not null,
  phone              text not null default '',
  website            text not null default '',
  rating             real,
  review_count       integer,
  business_status    text,
  result_rank        integer not null,
  matches_registered integer not null check (matches_registered in (0, 1)),
  search_query       text not null,
  searched_at        timestamptz not null,

  -- Added for WSS ------------------------------------------------------------
  location extensions.geography(Point, 4326) generated always as (
    extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)::extensions.geography
  ) stored,
  -- Parsed from Google's address: "<street>, <city>, <ST> <zip>[<+4>][, USA]".
  city  text generated always as (
    (regexp_match(address, '(?:^|,\s*)([^,]+),\s*[A-Z]{2}\s+\d{5}(?:-?\d{4})?(?:,\s*USA)?$'))[1]
  ) stored,
  place_state text generated always as (
    (regexp_match(address, ',\s*([A-Z]{2})\s+\d{5}(?:-?\d{4})?(?:,\s*USA)?$'))[1]
  ) stored,
  zip   text generated always as (
    (regexp_match(address, '[A-Z]{2}\s+(\d{5})(?:-?\d{4})?(?:,\s*USA)?$'))[1]
  ) stored,
  name_match     boolean,  -- place name matches the registered clinic name (admin only)
  first_batch_id integer not null references public.import_batches (batch_id),
  last_batch_id  integer not null references public.import_batches (batch_id),

  unique (clinic_id, place_id)
);

create index clinic_addresses_place_id_idx  on public.clinic_addresses (place_id);
create index clinic_addresses_clinic_id_idx on public.clinic_addresses (clinic_id);
create index clinic_addresses_zip_idx       on public.clinic_addresses (zip);
create index clinic_addresses_city_idx      on public.clinic_addresses (lower(city));
create index clinic_addresses_location_idx  on public.clinic_addresses using gist (location);

-- Individual dermatologists (only those linked to an imported clinic).
create table public.dermatologists (
  npi            text primary key,
  name           text not null,
  address1       text not null,
  address2       text not null default '',
  city           text not null,
  state          text not null,
  zip            text not null,
  phone          text not null default '',
  first_seen     date not null,
  last_seen      date not null,
  first_batch_id integer not null references public.import_batches (batch_id),
  last_batch_id  integer not null references public.import_batches (batch_id)
);

-- Doctor-to-clinic links inferred by the scraper (many-to-many).
create table public.assignments (
  npi         text not null references public.dermatologists (npi) on delete cascade,
  clinic_id   integer not null references public.clinics (clinic_id) on delete cascade,
  confidence  text not null check (confidence in ('high', 'medium')),
  derm_name   text not null default '',
  clinic_name text not null default '',
  first_batch_id integer not null references public.import_batches (batch_id),
  primary key (npi, clinic_id)
);

create index assignments_clinic_id_idx on public.assignments (clinic_id);

alter table public.clinics          enable row level security;
alter table public.clinic_addresses enable row level security;
alter table public.dermatologists   enable row level security;
alter table public.assignments      enable row level security;
