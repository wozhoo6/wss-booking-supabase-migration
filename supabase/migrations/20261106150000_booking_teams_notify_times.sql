-- Teams notification: one preferred time per line, hour without a leading zero.
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
    return null;
  end if;

  for r in
    select br.reference,
           br.full_name,
           br.phone,
           br.email,
           br.place_name,
           string_agg(
             n.slot_no::text || ') ' || to_char(n.preferred_at, 'Dy DD Mon YYYY, FMHH12:MI AM'),
             '<br>' order by n.slot_no
           ) as times_text
    from new_rows n
    join public.booking_requests br on br.id = n.booking_request_id
    group by br.id, br.reference, br.full_name, br.phone, br.email, br.place_name
  loop
    perform net.http_post(
      url     := v_url,
      body    := jsonb_build_object(
                   'reference',  coalesce(r.reference, ''),
                   'full_name',  coalesce(r.full_name, ''),
                   'phone',      coalesce(r.phone, ''),
                   'email',      coalesce(r.email, ''),
                   'place_name', coalesce(r.place_name, ''),
                   'times_text', coalesce(r.times_text, '')
                 ),
      headers := jsonb_build_object('Content-Type', 'application/json'),
      timeout_milliseconds := 5000
    );
  end loop;

  return null;
exception when others then
  raise warning 'booking notification failed: %', sqlerrm;
  return null;
end;
$$;
