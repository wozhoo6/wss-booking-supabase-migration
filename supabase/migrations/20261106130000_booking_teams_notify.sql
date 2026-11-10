-- Posts a message to a Microsoft Teams (Power Automate) flow whenever a booking
-- request is submitted.
--
-- The flow URL is NOT in this file. It lives in Supabase Vault under the name
-- 'booking_flow_url'. Set it once per project, from the SQL editor:
--
--   select vault.create_secret('<flow url>', 'booking_flow_url');
--
-- (to change it later: select vault.update_secret(id, '<new url>') from
--  vault.secrets where name = 'booking_flow_url';)
--
-- With no secret stored the trigger does nothing, so local and test databases
-- are unaffected. net.http_post (pg_net) only queues the request; it is sent
-- after the transaction commits, so a rolled-back booking sends nothing.

create extension if not exists pg_net with schema extensions;

create or replace function private.notify_booking_to_teams()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  r     record;
begin
  select ds.decrypted_secret into v_url
  from vault.decrypted_secrets ds
  where ds.name = 'booking_flow_url';

  if v_url is null then
    return null;  -- no URL stored: skip quietly
  end if;

  for r in
    select br.reference,
           br.full_name,   -- remove from here and the payload if names shouldn't go to Teams
           br.place_name,
           string_agg(
             n.slot_no::text || ') ' || to_char(n.preferred_at, 'Dy DD Mon YYYY, HH12:MI AM'),
             '; ' order by n.slot_no
           ) as times_text
    from new_rows n
    join public.booking_requests br on br.id = n.booking_request_id
    group by br.id, br.reference, br.full_name, br.place_name
  loop
    perform net.http_post(
      url     := v_url,
      body    := jsonb_build_object(
                   'reference',  r.reference,
                   'full_name',  r.full_name,
                   'place_name', r.place_name,
                   'times_text', r.
                 ),
      headers := jsonb_build_object('Content-Type', 'application/json'),
      timeout_milliseconds := 5000
    );
  end loop;

  return null;
exception when others then
  -- a notification problem must never break a booking
  raise warning 'booking notification failed: %', sqlerrm;
  return null;
end;
$$;

-- One firing per insert statement: submit_booking_request inserts the 3 slots
-- together, so a booking sends one message.
create or replace trigger booking_times_notify
after insert on public.booking_request_times
referencing new table as new_rows
for each statement
execute function private.notify_booking_to_teams();
