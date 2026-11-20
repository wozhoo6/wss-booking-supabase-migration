-- Paginate search_places with p_offset and report total / has_more.
-- Same shape as nearby_places (20261114000001): `clinics` and `count` keep
-- their meaning; `total`, `limit`, `offset` and `has_more` are new.
--
-- The old 2-arg function is dropped first so PostgREST doesn't see two
-- overloads (PGRST203).

drop function if exists public.search_places(text, integer);

create or replace function public.search_places(
  p_location text,
  p_limit    integer default 20,
  p_offset   integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_q       text := btrim(coalesce(p_location, ''));
  v_zip     text;
  v_pattern text;
  v_clinics jsonb;
  v_total   integer;
begin
  if v_q = '' then
    raise exception 'location is required' using errcode = '22023';
  end if;
  if length(v_q) > 100 then
    raise exception 'location must be at most 100 characters' using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'limit must be between 1 and 100' using errcode = '22023';
  end if;
  if p_offset is null or p_offset < 0 or p_offset > 10000 then
    raise exception 'offset must be between 0 and 10000' using errcode = '22023';
  end if;

  if v_q ~ '^\d{5}(-?\d{4})?$' then
    v_zip := left(v_q, 5);
  else
    v_pattern := '%' || private.like_escape(v_q) || '%';
  end if;

  -- public.places is a DISTINCT ON view over every address, so each scan of it
  -- is expensive. The total comes from a window count in the same pass as the
  -- page (count(*) over () is evaluated before LIMIT / OFFSET).
  with hits as (
    select p.place_id, p.priority_rank, p.place_name, count(*) over () as total
    from public.places p
    where private.is_public_status(p.business_status)
      and (case
             when v_zip is not null then p.zip = v_zip
             else p.city ilike v_pattern or p.address ilike v_pattern or p.place_name ilike v_pattern
           end)
    order by p.priority_rank asc nulls last, lower(p.place_name), p.place_id
    limit p_limit offset p_offset
  )
  select coalesce(jsonb_agg(private.place_json(h.place_id)
                            order by h.priority_rank asc nulls last, lower(h.place_name), h.place_id),
                  '[]'::jsonb),
         max(h.total)::integer
  into v_clinics, v_total
  from hits h;

  -- An empty page has no row to read the total from. Offset 0 means nothing
  -- matched; otherwise the offset ran past the end, so count once.
  if v_total is null then
    if p_offset = 0 then
      v_total := 0;
    else
      select count(*)::integer into v_total
      from public.places p
      where private.is_public_status(p.business_status)
        and (case
               when v_zip is not null then p.zip = v_zip
               else p.city ilike v_pattern or p.address ilike v_pattern or p.place_name ilike v_pattern
             end);
    end if;
  end if;

  return jsonb_build_object(
    'clinics',  v_clinics,
    'count',    jsonb_array_length(v_clinics),
    'total',    v_total,
    'limit',    p_limit,
    'offset',   p_offset,
    'has_more', p_offset + jsonb_array_length(v_clinics) < v_total);
end;
$$;

revoke all on function public.search_places(text, integer, integer) from public, anon, authenticated;
grant execute on function public.search_places(text, integer, integer) to anon, authenticated;
