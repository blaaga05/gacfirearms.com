create table public.gac_store_orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique,
  user_id uuid not null references auth.users(id) on delete restrict,
  customer_email text not null,
  items jsonb not null check (jsonb_typeof(items) = 'array'),
  subtotal_cents integer not null check (subtotal_cents >= 0),
  shipping_cents integer not null default 0 check (shipping_cents >= 0),
  tax_cents integer not null default 0 check (tax_cents >= 0),
  total_cents integer not null check (total_cents >= 0),
  currency text not null default 'USD' check (currency = 'USD'),
  payment_reference text,
  payment_status text not null default 'paid'
    check (payment_status in ('paid','partially_refunded','refunded')),
  fulfillment_status text not null default 'pending_fulfillment'
    check (fulfillment_status in ('pending_fulfillment','processing','shipped','delivered','cancelled')),
  shipping_address jsonb not null default '{}'::jsonb
    check (jsonb_typeof(shipping_address) = 'object'),
  carrier text,
  tracking_number text,
  tracking_url text check (tracking_url is null or tracking_url ~ '^https://'),
  shipped_at timestamptz,
  delivered_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);

create index gac_store_orders_user_created_idx on public.gac_store_orders (user_id, created_at desc);
create index gac_store_orders_status_created_idx on public.gac_store_orders (fulfillment_status, created_at desc);

alter table public.gac_store_orders enable row level security;
grant select, update on public.gac_store_orders to authenticated;

create policy gac_store_orders_customer_read
  on public.gac_store_orders for select to authenticated
  using (user_id = (select auth.uid()) and (select public.gac_is_member()));
create policy gac_store_orders_owner_read
  on public.gac_store_orders for select to authenticated
  using ((select public.gac_is_owner()));
create policy gac_store_orders_owner_update
  on public.gac_store_orders for update to authenticated
  using ((select public.gac_is_owner()))
  with check ((select public.gac_is_owner()));
