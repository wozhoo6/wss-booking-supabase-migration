-- WSS-owned tables. Batch imports never write to these.

-- Sponsored / pinned placement. No row = normal ranking.
create table public.address_priority (
  address_id    integer primary key references public.clinic_addresses (address_id) on delete cascade,
  priority_rank integer not null check (priority_rank > 0),
  note          text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger address_priority_set_updated_at
  before update on public.address_priority
  for each row execute function public.set_updated_at();

-- Append-only referral event log. address_id/place_id are not FKs so history
-- survives re-imports and reverts.
create table public.referral_interactions (
  id               uuid primary key default gen_random_uuid(),
  referral_id      text not null check (referral_id ~ '^REF-\d{4}-\d{6,}$'),
  screening_id     text,
  session_id       text,
  address_id       integer,
  place_id         text,
  place_name       text,
  interaction_type text not null check (interaction_type in (
                     'CLINIC_VIEWED', 'PHONE_CLICKED', 'WEBSITE_CLICKED',
                     'MAP_CLICKED', 'APPOINTMENT_CLICKED')),
  source           text not null default 'ai_screening_results',
  metadata         jsonb not null default '{}'::jsonb,
  search_location  text,
  created_at       timestamptz not null default now()
);

create index referral_interactions_referral_id_idx on public.referral_interactions (referral_id);
create index referral_interactions_place_id_idx    on public.referral_interactions (place_id);
create index referral_interactions_address_id_idx  on public.referral_interactions (address_id);
create index referral_interactions_created_at_idx  on public.referral_interactions (created_at);
create index referral_interactions_type_idx        on public.referral_interactions (interaction_type);

-- Collision-free REF-YYYY-###### ids (counter resets each year).
create table public.referral_counters (
  year       integer primary key,
  last_value integer not null
);

create or replace function public.next_referral_id()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  y integer := extract(year from now() at time zone 'utc')::integer;
  n integer;
begin
  insert into public.referral_counters as rc (year, last_value)
  values (y, 1)
  on conflict (year) do update set last_value = rc.last_value + 1
  returning last_value into n;

  return format('REF-%s-%s', y, lpad(n::text, 6, '0'));
end;
$$;

-- Admins (replaces the shared X-Admin-Key).
create table public.admin_users (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.admin_users where user_id = auth.uid());
$$;

alter table public.address_priority      enable row level security;
alter table public.referral_interactions enable row level security;
alter table public.referral_counters     enable row level security;
alter table public.admin_users           enable row level security;

-- Policies and grants for anon/admin are added in the API step.
revoke execute on function public.next_referral_id() from public, anon, authenticated;
