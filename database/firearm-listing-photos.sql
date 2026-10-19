-- Public catalog photo path; public image bytes remain in the existing public product image bucket.
alter table public.gac_firearm_inventory
  add column if not exists photo_path text;

grant select (photo_path)
  on public.gac_firearm_inventory
  to anon, authenticated;

create or replace view public.gac_firearm_catalog
with (security_barrier = true, security_invoker = true)
as
select fastbound_item_id as id, manufacturer, model, caliber, firearm_type, condition,
       barrel_length, overall_length, price_cents, public_description, photo_path
from public.gac_firearm_inventory
where published and is_available and price_cents is not null;
