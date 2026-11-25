-- Scan monitoring: one anonymous row per /predict call, written by the FastAPI
-- backend and read by the /admin/monitoring page.
--
--   log_scan_event       ingest token   backend only; inserts one row
--   admin_scan_metrics   admin key      totals, per-day counts, top conditions
--
-- No photos, names, contact details or answers are stored: only the outcome,
-- the top condition, urgency, token counts, latency, model and how many of the
-- optional questions were answered.
--
-- The backend calls log_scan_event with the publishable key, so the function
-- checks a separate ingest token (its SHA-256 hash lives in private, like the
-- admin key). Set it once in the SQL editor, then put the same token in the
-- backend's SCAN_LOG_TOKEN env var:
--   select private.set_scan_ingest_token('<long random token>');
--
-- Errors follow the other functions: 28000 invalid key, 22023 invalid input.

---------------------------------------------------------------------------
-- Table (no direct access: RLS on, no policies, privileges revoked)
---------------------------------------------------------------------------
create table if not exists public.scan_events (
  id                 bigint generated always as identity primary key,
  created_at         timestamptz not null default now(),
  status             text not null check (status in ('success', 'rejected', 'failed')),
  top_condition      text check (char_length(top_condition) <= 80),
  urgency            text check (urgency in ('ROUTINE', 'URGENT', 'IMMEDIATE')),
  model              text check (char_length(model) <= 60),
  input_tokens       integer check (input_tokens between 0 and 1000000),
  output_tokens      integer check (output_tokens between 0 and 1000000),
  latency_ms         integer check (latency_ms between 0 and 600000),
  questions_answered smallint check (questions_answered between 0 and 20),
  error_code         text check (char_length(error_code) <= 60)
);

create index if not exists scan_events_created_at_idx on public.scan_events (created_at desc);

alter table public.scan_events enable row level security;
revoke all on table public.scan_events from public, anon, authenticated;

---------------------------------------------------------------------------
-- Ingest token
---------------------------------------------------------------------------
create table if not exists private.scan_ingest_settings (
  id         boolean primary key default true check (id),
  token_hash bytea not null
);

-- Applied in prod: RLS on with no policies, like public.scan_events
alter table private.scan_ingest_settings enable row level security;

create or replace function private.set_scan_ingest_token(p_token text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_token is null or char_length(p_token) < 32 then
    raise exception 'the ingest token must be at least 32 characters' using errcode = '22023';
  end if;
  insert into private.scan_ingest_settings (id, token_hash)
  values (true, extensions.digest(p_token, 'sha256'))
  on conflict (id) do update set token_hash = excluded.token_hash;
end;
$$;

revoke all on function private.set_scan_ingest_token(text) from public, anon, authenticated;

---------------------------------------------------------------------------
-- log_scan_event: called by the backend after every scan
---------------------------------------------------------------------------
create or replace function public.log_scan_event(p_token text, p_event jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash bytea;
begin
  select token_hash into v_hash from private.scan_ingest_settings where id;
  if v_hash is null or p_token is null or extensions.digest(p_token, 'sha256') <> v_hash then
    raise exception 'invalid ingest token' using errcode = '28000';
  end if;
  if p_event is null or jsonb_typeof(p_event) <> 'object' then
    raise exception 'p_event must be an object' using errcode = '22023';
  end if;

  insert into public.scan_events (
    status, top_condition, urgency, model, input_tokens, output_tokens,
    latency_ms, questions_answered, error_code
  ) values (
    p_event->>'status',
    nullif(p_event->>'top_condition', ''),
    nullif(p_event->>'urgency', ''),
    nullif(p_event->>'model', ''),
    (p_event->>'input_tokens')::integer,
    (p_event->>'output_tokens')::integer,
    (p_event->>'latency_ms')::integer,
    (p_event->>'questions_answered')::smallint,
    nullif(p_event->>'error_code', '')
  );
exception
  when check_violation or invalid_text_representation or numeric_value_out_of_range then
    raise exception 'invalid scan event: %', sqlerrm using errcode = '22023';
end;
$$;

---------------------------------------------------------------------------
-- admin_scan_metrics: everything the monitoring page shows, for the last
-- p_days days (1-90, days in UTC, today included)
---------------------------------------------------------------------------
create or replace function public.admin_scan_metrics(p_admin_key text, p_days integer default 14)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_days  integer := least(greatest(coalesce(p_days, 14), 1), 90);
  v_start timestamptz;
  v_result jsonb;
begin
  perform private.require_admin(p_admin_key);
  v_start := date_trunc('day', now() at time zone 'utc') at time zone 'utc' - (v_days - 1) * interval '1 day';

  with ev as (
    select * from public.scan_events where created_at >= v_start
  )
  select jsonb_build_object(
    'days', v_days,
    'since', v_start,
    'totals', (
      select jsonb_build_object(
        'scans',          count(*),
        'success',        count(*) filter (where status = 'success'),
        'rejected',       count(*) filter (where status = 'rejected'),
        'failed',         count(*) filter (where status = 'failed'),
        'with_answers',   count(*) filter (where status = 'success' and questions_answered > 0),
        'input_tokens',   coalesce(sum(input_tokens), 0),
        'output_tokens',  coalesce(sum(output_tokens), 0),
        'avg_latency_ms', round(avg(latency_ms) filter (where status = 'success')),
        'p90_latency_ms', round((percentile_cont(0.9) within group (order by latency_ms)
                                  filter (where status = 'success'))::numeric)
      )
      from ev
    ),
    'daily', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'day', to_char(d.day, 'YYYY-MM-DD'),
               'scans', coalesce(c.scans, 0),
               'failed', coalesce(c.failed, 0)
             ) order by d.day), '[]'::jsonb)
      from generate_series(v_start, v_start + (v_days - 1) * interval '1 day', interval '1 day') as d(day)
      left join (
        select date_trunc('day', created_at at time zone 'utc') at time zone 'utc' as day,
               count(*) as scans,
               count(*) filter (where status <> 'success') as failed
        from ev
        group by 1
      ) c on c.day = d.day
    ),
    'top_conditions', (
      select coalesce(jsonb_agg(jsonb_build_object('condition', top_condition, 'scans', n) order by n desc, top_condition), '[]'::jsonb)
      from (
        select top_condition, count(*) as n
        from ev
        where status = 'success' and top_condition is not null
        group by 1
        order by 2 desc, 1
        limit 10
      ) t
    ),
    'urgency', (
      select coalesce(jsonb_object_agg(urgency, n), '{}'::jsonb)
      from (select urgency, count(*) as n from ev where status = 'success' and urgency is not null group by 1) u
    ),
    'models', (
      select coalesce(jsonb_object_agg(model, n), '{}'::jsonb)
      from (select model, count(*) as n from ev where model is not null group by 1) m
    ),
    'recent_problems', (
      select coalesce(jsonb_agg(jsonb_build_object('at', created_at, 'status', status, 'error_code', error_code) order by created_at desc), '[]'::jsonb)
      from (select created_at, status, error_code from ev where status <> 'success' order by created_at desc limit 10) p
    )
  ) into v_result;

  return v_result;
end;
$$;

---------------------------------------------------------------------------
-- Grants
---------------------------------------------------------------------------
revoke all on function public.log_scan_event(text, jsonb) from public, anon, authenticated;
revoke all on function public.admin_scan_metrics(text, integer) from public, anon, authenticated;

grant execute on function public.log_scan_event(text, jsonb) to anon, authenticated;
grant execute on function public.admin_scan_metrics(text, integer) to anon, authenticated;
