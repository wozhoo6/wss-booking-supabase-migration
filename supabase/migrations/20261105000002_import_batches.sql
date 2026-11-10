-- One row per scraper DB file loaded (Texas = batch 1, later regions follow).
create table public.import_batches (
  batch_id                integer generated always as identity primary key,
  region                  text not null,
  source_file             text not null,
  source_sha256           text,
  status                  text not null default 'pending'
                          check (status in ('pending', 'dry_run', 'committed', 'failed', 'reverted')),
  clinics_inserted        integer not null default 0,
  clinics_updated         integer not null default 0,
  addresses_inserted      integer not null default 0,
  addresses_updated       integer not null default 0,
  dermatologists_inserted integer not null default 0,
  dermatologists_updated  integer not null default 0,
  assignments_inserted    integer not null default 0,
  skipped_no_google       integer not null default 0,
  notes                   text,
  imported_at             timestamptz not null default now()
);

alter table public.import_batches enable row level security;
