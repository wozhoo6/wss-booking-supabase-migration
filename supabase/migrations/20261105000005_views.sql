-- Derived views. Access is granted in the API step; for now only service_role reads them.

-- Public search surface: one row per unique Google place.
create view public.places
with (security_invoker = true)
as
with ranked as (
  select distinct on (ca.place_id)
    ca.address_id, ca.place_id, ca.place_name, ca.address, ca.city, ca.place_state,
    ca.zip, ca.lat, ca.lng, ca.location, ca.phone, ca.website, ca.rating,
    ca.review_count, ca.business_status
  from public.clinic_addresses ca
  order by ca.place_id, ca.matches_registered desc, ca.result_rank, ca.address_id
),
priority as (
  select ca.place_id, min(ap.priority_rank) as priority_rank
  from public.address_priority ap
  join public.clinic_addresses ca using (address_id)
  group by ca.place_id
)
select r.*, p.priority_rank
from ranked r
left join priority p using (place_id);

-- Admin: registered clinics behind each place, with match confidence for outreach.
create view public.place_registered_clinics
with (security_invoker = true)
as
select
  ca.place_id,
  ca.address_id,
  c.clinic_id,
  c.npi,
  c.name     as registered_name,
  concat_ws(' ', c.address1, nullif(c.address2, '')) as registered_address,
  c.city     as registered_city,
  c.state    as registered_state,
  c.zip      as registered_zip,
  c.phone    as registered_phone,
  ca.matches_registered,
  ca.name_match,
  case
    when ca.matches_registered = 1 then 'address_verified'
    when ca.name_match            then 'name_match'
    else 'needs_review'
  end as match_confidence,
  case
    when ca.matches_registered = 1 then 1
    when ca.name_match            then 2
    else 3
  end as confidence_order
from public.clinic_addresses ca
join public.clinics c using (clinic_id);

-- Doctors per place, via every registered clinic linked to the place.
create view public.place_dermatologists
with (security_invoker = true)
as
select distinct on (ca.place_id, d.npi)
  ca.place_id,
  d.npi,
  d.name,
  a.confidence
from public.clinic_addresses ca
join public.assignments a    using (clinic_id)
join public.dermatologists d using (npi)
order by ca.place_id, d.npi, (a.confidence = 'high') desc;
