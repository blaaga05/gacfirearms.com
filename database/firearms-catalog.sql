-- FastBound-backed serialized inventory and separated firearm order requests.
-- Apply only after the code in feat/fastbound-firearm-catalog-checkout is reviewed.

create table if not exists public.gac_firearm_inventory (
  fastbound_item_id uuid primary key,
  item_number text not null default '',
  serial_number text not null,
  manufacturer text not null default '',
  model text not null default '',
  caliber text not null default '',
  firearm_type text not null default '',
  condition text not null default '',
  barrel_length numeric(7,3),
  overall_length numeric(7,3),
  manufacturer_part_number text not null default '',
  upc text not null default '',
  sku text not null default '',
  fastbound_status_id integer,
  is_available boolean not null default false,
  price_cents integer check (price_cents is null or price_cents > 0),
  public_description text not null default '',
  published boolean not null default false,
  synced_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.gac_firearm_inventory enable row level security;
revoke all on public.gac_firearm_inventory from anon, authenticated;
grant all on public.gac_firearm_inventory to service_role;

drop policy if exists gac_firearm_public_catalog_read on public.gac_firearm_inventory;
create policy gac_firearm_public_catalog_read
  on public.gac_firearm_inventory
  for select
  to anon, authenticated
  using (published and is_available and price_cents is not null);

grant select (
  fastbound_item_id, manufacturer, model, caliber, firearm_type, condition,
  barrel_length, overall_length, price_cents, public_description,
  published, is_available
) on public.gac_firearm_inventory to anon, authenticated;

create or replace view public.gac_firearm_catalog
with (security_barrier = true, security_invoker = true)
as
select fastbound_item_id as id, manufacturer, model, caliber, firearm_type, condition,
       barrel_length, overall_length, price_cents, public_description
from public.gac_firearm_inventory
where published and is_available and price_cents is not null;

revoke all on public.gac_firearm_catalog from anon, authenticated;
grant select on public.gac_firearm_catalog to anon, authenticated, service_role;

create table if not exists public.gac_firearm_order_requests (
  id uuid primary key default gen_random_uuid(),
  firearm_item_id uuid not null,
  firearm_name text not null,
  price_cents integer not null check (price_cents > 0),
  buyer_name text not null,
  buyer_email text not null,
  buyer_phone text not null default '',
  residence_state char(2) not null,
  transfer_method text not null check (transfer_method in ('local_pickup', 'destination_ffl')),
  destination_ffl_name text not null default '',
  destination_ffl_city text not null default '',
  destination_ffl_state char(2),
  destination_ffl_phone text not null default '',
  destination_ffl_email text not null default '',
  buyer_affirms_eligibility boolean not null check (buyer_affirms_eligibility),
  buyer_acknowledges_review boolean not null check (buyer_acknowledges_review),
  review_status text not null default 'pending_review'
    check (review_status in ('pending_review', 'contacted', 'declined')),
  created_at timestamptz not null default now()
);

create index if not exists gac_firearm_requests_email_created_idx
  on public.gac_firearm_order_requests (buyer_email, created_at desc);
create index if not exists gac_firearm_requests_pending_idx
  on public.gac_firearm_order_requests (created_at desc)
  where review_status = 'pending_review';

alter table public.gac_firearm_order_requests enable row level security;
revoke all on public.gac_firearm_order_requests from anon, authenticated;
grant all on public.gac_firearm_order_requests to service_role;

comment on table public.gac_firearm_inventory is
  'Private owner/service-role inventory mirror. Serial numbers are never exposed through the public catalog view.';
comment on table public.gac_firearm_order_requests is
  'Private firearm order inquiries. Requests require owner review and do not reserve inventory or collect payment.';
