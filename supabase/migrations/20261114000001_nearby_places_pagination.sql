-- Paginate nearby_places with p_offset and report total / has_more.
--
-- Same ordering as before (pinned places first, then nearest, place_id as the
-- final tiebreaker), so offset pages are stable. `clinics` and `count` keep
-- their meaning; `total`, `limit`, `offset` and `has_more` are new.
--
-- The old 4-arg function is dropped first: leaving it next to the new 5-arg
-- one would make PostgREST reject calls as ambiguous (PGRST203).

drop function if exists public.nearby_places(double precision, double precision, double precision, integer);

create or replace function public.nearby_places(
  p_lat       double precision,
  p_lng       double precision,
  p_radius_km double precision default 25,
  p_limit     integer default 20,
  p_offset    integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_point   extensions.geography;
  v_clinics jsonb;
  v_total   integer;
begin
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'lat must be between -90 and 90 and lng between -180 and 180' using errcode = '22023';
  end if;
  if p_radius_km is null or p_radius_km <= 0 or p_radius_km > 200 then
    raise exception 'radius_km must be greater than 0 and at most 200' using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'limit must be between 1 and 100' using errcode = '22023';
  end if;
  if p_offset is null or p_offset < 0 or p_offset > 10000 then
    raise exception 'offset must be between 0 and 10000' using errcode = '22023';
  end if;

  v_point := extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography;

  -- public.places is a DISTINCT ON view over every address, so each scan of it
  -- is expensive. The total comes from a window count in the same pass as the
  -- page (count(*) over () is evaluated before LIMIT / OFFSET).
  with hits as (
    select p.place_id, p.priority_rank,
           extensions.st_distance(p.location, v_point) as dist_m,
           count(*) over () as total
    from public.places p
    where extensions.st_dwithin(p.location, v_point, p_radius_km * 1000)
      and private.is_public_status(p.business_status)
    order by p.priority_rank asc nulls last, dist_m, p.place_id
    limit p_limit offset p_offset
  )
  select coalesce(jsonb_agg(private.place_json(h.place_id, h.dist_m / 1000.0)
                            order by h.priority_rank asc nulls last, h.dist_m, h.place_id),
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
      where extensions.st_dwithin(p.location, v_point, p_radius_km * 1000)
        and private.is_public_status(p.business_status);
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

revoke all on function public.nearby_places(double precision, double precision, double precision, integer, integer) from public, anon, authenticated;
grant execute on function public.nearby_places(double precision, double precision, double precision, integer, integer) to anon, authenticated;
