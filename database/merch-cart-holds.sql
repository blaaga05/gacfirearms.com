begin;

create table gac_private.merch_carts(
 id uuid primary key,
 access_hash text not null check(access_hash~'^[a-f0-9]{64}$'),
 expires_at timestamptz not null,
 created_at timestamptz not null default clock_timestamp()
);
create index merch_carts_expiry on gac_private.merch_carts(expires_at);

create table gac_private.merch_cart_holds(
 cart_id uuid not null references gac_private.merch_carts(id) on delete cascade,
 product_id uuid not null references public.gac_merch_products(id) on delete cascade,
 size text not null,
 quantity integer not null check(quantity between 1 and 99),
 primary key(cart_id,product_id,size)
);
create index merch_cart_holds_variant on gac_private.merch_cart_holds(product_id,size);
alter table gac_private.merch_carts enable row level security;
alter table gac_private.merch_cart_holds enable row level security;
revoke all on gac_private.merch_carts,gac_private.merch_cart_holds from public,anon,authenticated;

create or replace function gac_private.merch_available(p_product uuid,p_size text,p_except uuid default null)
returns integer language sql stable security definer set search_path=''as $$
 select greatest(0,s.quantity
  -coalesce((select sum(h.quantity) from gac_private.merch_order_holds h join gac_private.merch_orders o on o.id=h.order_id where h.product_id=p_product and h.size=p_size and o.id is distinct from p_except and (o.state='review' or o.state='pending' and (o.expires_at>clock_timestamp() or o.token_claimed_at is not null and coalesce(o.payment_checked_at,'-infinity'::timestamptz)<o.expires_at))),0)
  -coalesce((select sum(h.quantity) from gac_private.merch_cart_holds h join gac_private.merch_carts c on c.id=h.cart_id where h.product_id=p_product and h.size=p_size and h.cart_id is distinct from p_except and c.expires_at>clock_timestamp()),0)
 )::integer from public.gac_merch_stock s where s.product_id=p_product and s.size=p_size and s.quantity is not null;
$$;
revoke all on function gac_private.merch_available(uuid,text,uuid) from public,anon,authenticated;

create or replace function public.gac_set_merch_cart_hold(p_id uuid,p_access_hash text,p_cart jsonb)
returns jsonb language plpgsql security definer set search_path=''as $$
declare c gac_private.merch_carts;l jsonb;p public.gac_merch_products;sn text;n integer;expiry timestamptz;
begin
 if(select auth.role()) is distinct from 'service_role' then raise exception 'Service access required';end if;
 if p_id is null or p_access_hash is null or p_access_hash!~'^[a-f0-9]{64}$' or p_cart is null or jsonb_typeof(p_cart)<>'array' or jsonb_array_length(p_cart)>10 then raise exception 'Invalid cart';end if;
 delete from gac_private.merch_carts where expires_at<=clock_timestamp();
 if exists(select 1 from gac_private.merch_orders where id=p_id) then raise exception 'This cart already has a checkout in progress';end if;
 select * into c from gac_private.merch_carts where id=p_id for update;
 if found then
  if c.access_hash<>p_access_hash then raise exception 'Invalid cart access';end if;
  expiry:=case when c.expires_at<=clock_timestamp() then clock_timestamp()+interval '20 minutes' else c.expires_at end;
 else expiry:=clock_timestamp()+interval '20 minutes';end if;
 if jsonb_array_length(p_cart)=0 then delete from gac_private.merch_carts where id=p_id;return jsonb_build_object('held',false);end if;
 if(select count(distinct(x->>'id',x->>'size')) from jsonb_array_elements(p_cart)x)<>jsonb_array_length(p_cart) then raise exception 'Combine duplicate cart lines';end if;
 insert into gac_private.merch_carts(id,access_hash,expires_at) values(p_id,p_access_hash,expiry) on conflict(id) do update set expires_at=excluded.expires_at;
 for l in select x from jsonb_array_elements(p_cart)x order by x->>'id',x->>'size' loop
  if coalesce(l->>'quantity','')!~'^[1-9][0-9]?$' then raise exception 'Choose whole quantities from 1 to 99';end if;
  n:=(l->>'quantity')::integer;sn:=l->>'size';
  select * into strict p from public.gac_merch_products where id=(l->>'id')::uuid for update;
  if not p.published or p.price_pending or not sn=any(p.sizes) then raise exception 'An item is unavailable or awaiting a price';end if;
  perform 1 from public.gac_merch_stock where product_id=p.id and size=sn for update;
  if coalesce(gac_private.merch_available(p.id,sn,p_id),-1)<n then raise exception 'Not enough stock for % (%)',p.name,sn;end if;
 end loop;
 delete from gac_private.merch_cart_holds where cart_id=p_id;
 insert into gac_private.merch_cart_holds(cart_id,product_id,size,quantity)
 select p_id,(x->>'id')::uuid,x->>'size',(x->>'quantity')::integer from jsonb_array_elements(p_cart)x;
 return jsonb_build_object('held',true,'expires_at',expiry);
end $$;
revoke all on function public.gac_set_merch_cart_hold(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.gac_set_merch_cart_hold(uuid,text,jsonb) to service_role;

create or replace function public.gac_begin_merch_checkout_from_cart(p_id uuid,p_access_hash text,p_client_hash text,p_cart jsonb,p_shipping jsonb,p_tax_bps integer)
returns jsonb language plpgsql security definer set search_path=''as $$
declare c gac_private.merch_carts;result jsonb;existing gac_private.merch_orders;expected integer;actual integer;
begin
 if(select auth.role()) is distinct from 'service_role' then raise exception 'Service access required';end if;
 if p_id is null or p_access_hash is null or p_access_hash!~'^[a-f0-9]{64}$' or p_cart is null or jsonb_typeof(p_cart)<>'array' or jsonb_array_length(p_cart)>10 then raise exception 'Invalid cart';end if;
 select * into existing from gac_private.merch_orders where id=p_id for update;
 if found then
  if existing.access_hash<>p_access_hash then raise exception 'Invalid order access';end if;
  return public.gac_begin_merch_checkout(p_id,p_access_hash,p_client_hash,p_cart,p_shipping,p_tax_bps);
 end if;
 select * into strict c from gac_private.merch_carts where id=p_id for update;
 if c.access_hash<>p_access_hash then raise exception 'Invalid cart access';end if;
 if c.expires_at<=clock_timestamp() then raise exception 'Your cart hold expired. Update your cart to reserve available items again.';end if;
 select count(*) into expected from jsonb_array_elements(p_cart);
 select count(*) into actual from gac_private.merch_cart_holds where cart_id=p_id;
 if expected<>actual or exists(select 1 from jsonb_array_elements(p_cart)x where not exists(select 1 from gac_private.merch_cart_holds h where h.cart_id=p_id and h.product_id=(x->>'id')::uuid and h.size=x->>'size' and h.quantity=(x->>'quantity')::integer)) then raise exception 'Cart changed. Refresh the cart hold and review again.';end if;
 delete from gac_private.merch_cart_holds where cart_id=p_id;
 delete from gac_private.merch_carts where id=p_id;
 result:=public.gac_begin_merch_checkout(p_id,p_access_hash,p_client_hash,p_cart,p_shipping,p_tax_bps);
 update gac_private.merch_orders set expires_at=c.expires_at where id=p_id returning expires_at into c.expires_at;
 return result||jsonb_build_object('expires_at',c.expires_at);
end $$;
revoke all on function public.gac_begin_merch_checkout_from_cart(uuid,text,text,jsonb,jsonb,integer) from public,anon,authenticated;
grant execute on function public.gac_begin_merch_checkout_from_cart(uuid,text,text,jsonb,jsonb,integer) to service_role;

commit;
