-- Server-side sorting for the booking requests list, so the admin page can drop
-- its load-everything-and-sort-in-the-browser approach.
--
-- admin_list_booking_requests gets a trailing p_sort argument. The values are
-- the keys the admin page's Sort dropdown already uses:
--
--   newest   (default)  created_at, newest first
--   oldest              created_at, oldest first
--   soonest             first-choice time (slot 1), earliest first
--   patient             full_name A-Z, ignoring case
--   clinic              clinic name A-Z, ignoring case
--   status              workflow order: new, contacting_clinic, booked,
--                       attended, no_show, cancelled, closed
--
-- Ties always fall back to newest first, then id, so paging is stable.
-- Status, text search and clinic filtering already ran on the server; sorting
-- now runs there too, before the page is cut, so every page is in order.
--
-- Each request object also gets clinic_id and clinic_name (copies of place_id
-- and place_name): the admin page reads those names.

---------------------------------------------------------------------------
-- Request object: add clinic_id / clinic_name
---------------------------------------------------------------------------
create or replace function private.booking_request_json(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select to_jsonb(br) || jsonb_build_object(
           'clinic_id',   br.place_id,
           'clinic_name', br.place_name,
           'preferred_times', coalesce((
             select jsonb_agg(to_char(t.preferred_at, 'YYYY-MM-DD"T"HH24:MI') order by t.slot_no)
             from public.booking_request_times t
             where t.booking_request_id = br.id), '[]'::jsonb))
  from public.booking_requests br
  where br.id = p_id;
$$;

---------------------------------------------------------------------------
-- List: same filters as before, plus p_sort. A new signature, so the old
-- function is dropped first (create or replace would leave both).
---------------------------------------------------------------------------
drop function if exists public.admin_list_booking_requests(text, text, text, text, integer, integer);

create function public.admin_list_booking_requests(
  p_admin_key text,
  p_status    text default null,
  p_query     text default null,
  p_place_id  text default null,
  p_limit     integer default 50,
  p_offset    integer default 0,
  p_sort      text default 'newest'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_status  text := nullif(btrim(p_status), '');
  v_q       text := nullif(btrim(p_query), '');
  v_place   text := nullif(btrim(p_place_id), '');
  v_sort    text := coalesce(nullif(btrim(p_sort), ''), 'newest');
  v_pattern text;
  v_total   integer;
  v_rows    jsonb;
  v_counts  jsonb;
begin
  perform private.require_admin(p_admin_key);

  if v_status is not null and v_status not in
     ('new', 'contacting_clinic', 'booked', 'attended', 'no_show', 'cancelled', 'closed') then
    raise exception 'invalid status: %', v_status using errcode = '22023';
  end if;
  if v_sort not in ('newest', 'oldest', 'soonest', 'patient', 'clinic', 'status') then
    raise exception 'invalid sort: %', v_sort using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 1000 then
    raise exception 'limit must be between 1 and 1000' using errcode = '22023';
  end if;
  if p_offset is null or p_offset < 0 then
    raise exception 'offset must be 0 or more' using errcode = '22023';
  end if;

  v_pattern := '%' || private.like_escape(coalesce(v_q, '')) || '%';

  with base as (
    select br.id, br.status, br.created_at, br.full_name, br.place_name,
           (select t.preferred_at
            from public.booking_request_times t
            where t.booking_request_id = br.id and t.slot_no = 1) as first_choice
    from public.booking_requests br
    where (v_place is null or br.place_id = v_place)
      and (v_q is null
           or br.full_name  ilike v_pattern or br.email      ilike v_pattern
           or br.phone      ilike v_pattern or br.reference  ilike v_pattern
           or br.place_name ilike v_pattern)
  ),
  ordered as (
    select b.id,
           row_number() over (order by
             case when v_sort = 'oldest'  then b.created_at end asc,
             case when v_sort = 'soonest' then b.first_choice end asc nulls last,
             case when v_sort = 'patient' then lower(b.full_name) end asc,
             case when v_sort = 'clinic'  then lower(b.place_name) end asc nulls last,
             case when v_sort = 'status'  then array_position(
               array['new', 'contacting_clinic', 'booked', 'attended', 'no_show', 'cancelled', 'closed'],
               b.status) end asc,
             b.created_at desc, b.id) as rn
    from base b
    where v_status is null or b.status = v_status
  ),
  page as (
    select o.id, o.rn
    from ordered o
    order by o.rn
    limit p_limit offset p_offset
  )
  select (select count(*) from base b where v_status is null or b.status = v_status),
         coalesce((select jsonb_agg(private.booking_request_json(p.id) order by p.rn)
                   from page p), '[]'::jsonb),
         (select jsonb_object_agg(s.status, coalesce(c.n, 0))
          from unnest(array['new', 'contacting_clinic', 'booked', 'attended',
                            'no_show', 'cancelled', 'closed']) as s(status)
          left join (select b.status, count(*) as n from base b group by b.status) c
                 on c.status = s.status)
  into v_total, v_rows, v_counts;

  return jsonb_build_object('requests', v_rows, 'total', v_total, 'counts_by_status', v_counts);
end;
$$;

revoke all on function public.admin_list_booking_requests(text, text, text, text, integer, integer, text) from public, anon, authenticated;
grant execute on function public.admin_list_booking_requests(text, text, text, text, integer, integer, text) to anon, authenticated;
