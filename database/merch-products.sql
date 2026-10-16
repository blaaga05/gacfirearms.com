begin;
create table public.gac_merch_products (
 id uuid primary key default gen_random_uuid(),
 name text not null check(char_length(name) between 1 and 120),
 description text not null default '' check(char_length(description)<=3000),
 price_cents integer not null check(price_cents between 1 and 10000000),
 sizes text[] not null default array['S','M','L','XL','2XL','3XL']::text[] check(cardinality(sizes) between 1 and 20),
 image_path text not null default '/assets/gac-shirt.png' check(image_path like '/assets/%' or image_path like 'https://%'),
 published boolean not null default false,
 sort_order integer not null default 0,
 created_at timestamptz not null default now()
);
alter table public.gac_merch_products enable row level security;
revoke all on public.gac_merch_products from anon,authenticated;
grant select on public.gac_merch_products to anon,authenticated;
grant insert,update,delete on public.gac_merch_products to authenticated;
create policy merch_public_read on public.gac_merch_products for select to anon using(published);
create policy merch_member_read on public.gac_merch_products for select to authenticated using(published or (select public.gac_is_owner()));
create policy merch_owner_insert on public.gac_merch_products for insert to authenticated with check((select public.gac_is_owner()));
create policy merch_owner_update on public.gac_merch_products for update to authenticated using((select public.gac_is_owner())) with check((select public.gac_is_owner()));
create policy merch_owner_delete on public.gac_merch_products for delete to authenticated using((select public.gac_is_owner()));
insert into public.gac_merch_products(name,description,price_cents,image_path,published) values('GAC Built for Purpose Tee','GAC on the front. Built for Purpose on the back. An olive green tee featuring the Gassett Arms Company flag design.',3000,'/assets/gac-shirt.png',true);
commit;
