-- Owner-only preparation for a future firearm checkout. This stores editable
-- shipping and jurisdiction tax values; no payment or catalog behavior is enabled.
begin;
create table if not exists public.gac_firearm_checkout_pricing (
  singleton boolean primary key default true check (singleton),
  shipping_cents integer not null default 0
    check (shipping_cents >= 0 and shipping_cents <= 1000000),
  tax_rates jsonb not null default '[]'::jsonb
    check (jsonb_typeof(tax_rates) = 'array'),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

insert into public.gac_firearm_checkout_pricing(singleton)
values (true)
on conflict (singleton) do nothing;

alter table public.gac_firearm_checkout_pricing enable row level security;
revoke all on public.gac_firearm_checkout_pricing from public, anon, authenticated;
grant all on public.gac_firearm_checkout_pricing to service_role;

comment on table public.gac_firearm_checkout_pricing is
  'Owner-only draft firearm checkout pricing. Settings are not consumed by customer checkout until a separately reviewed payment flow is enabled.';
commit;
