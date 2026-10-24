begin;

-- Product-level fulfillment pricing is stored alongside the editable catalog item.
alter table public.gac_merch_products
 add column shipping_cents integer not null default 0 check(shipping_cents between 0 and 100000),
 add column tax_bps integer not null default 0 check(tax_bps between 0 and 10000);

-- Preserve any previously entered store-wide values when moving to product pricing.
update public.gac_merch_products p
set shipping_cents=s.shipping_cents,tax_bps=s.tax_bps
from gac_private.merch_checkout_settings s
where s.singleton;

create or replace function public.gac_begin_merch_checkout(p_id uuid,p_access_hash text,p_client_hash text,p_cart jsonb)
returns jsonb language plpgsql security definer set search_path=''as $$
declare o gac_private.merch_orders;p public.gac_merch_products;l jsonb;sn text;n integer;subtotal integer:=0;shipping integer:=0;tax integer:=0;lines jsonb:='[]';settings gac_private.merch_checkout_settings;
begin
 if(select auth.role())is distinct from 'service_role'then raise exception 'Service access required';end if;
 select * into strict settings from gac_private.merch_checkout_settings where singleton for update;if not settings.enabled then raise exception 'Merchandise checkout is temporarily unavailable';end if;
 if p_id is null or p_access_hash is null or p_client_hash is null or p_cart is null or p_access_hash!~'^[a-f0-9]{64}$'or p_client_hash!~'^[a-f0-9]{64}$'or jsonb_typeof(p_cart)<>'array'or jsonb_array_length(p_cart)not between 1 and 10 then raise exception 'Invalid cart';end if;
 select * into o from gac_private.merch_orders where id=p_id for update;
 if found then if o.access_hash<>p_access_hash then raise exception 'Invalid order access';end if;if o.state<>'pending'or o.expires_at<=clock_timestamp()then raise exception 'Checkout expired or already processed. Start a fresh checkout';end if;return jsonb_build_object('id',o.id,'invoice',o.invoice,'total_cents',o.total_cents,'expires_at',o.expires_at);end if;
 if(select count(*)from gac_private.merch_orders where client_hash=p_client_hash and created_at>clock_timestamp()-interval '1 hour')>=10 or(select count(*)from gac_private.merch_orders where state='pending'and expires_at>clock_timestamp())>=30 then raise exception 'Too many checkout attempts. Try again later';end if;
 if(select count(distinct(x->>'id',x->>'size'))from jsonb_array_elements(p_cart)x)<>jsonb_array_length(p_cart)then raise exception 'Combine duplicate cart lines';end if;
 for l in select x from jsonb_array_elements(p_cart)x order by x->>'id',x->>'size' loop
  if coalesce(l->>'quantity','')!~'^[1-9][0-9]?$'then raise exception 'Choose whole quantities from 1 to 99';end if;n:=(l->>'quantity')::integer;sn:=l->>'size';
  select * into strict p from public.gac_merch_products where id=(l->>'id')::uuid for update;
  if not p.published or p.price_pending or not sn=any(p.sizes)then raise exception 'An item is unavailable or awaiting a price';end if;
  perform 1 from public.gac_merch_stock where product_id=p.id and size=sn for update;
  if coalesce(gac_private.merch_available(p.id,sn),-1)<n then raise exception 'Not enough stock for % (%)',p.name,sn;end if;
  subtotal:=subtotal+p.price_cents*n;
  shipping:=shipping+p.shipping_cents*n;
  tax:=tax+round(p.price_cents*n*p.tax_bps/10000.0)::integer;
  lines:=lines||jsonb_build_array(jsonb_build_object('id',p.id,'name',p.name,'size',sn,'quantity',n,'unit_cents',p.price_cents,'shipping_unit_cents',p.shipping_cents,'tax_bps',p.tax_bps,'image_path',p.image_path));
 end loop;
 if subtotal+shipping+tax>1000000 then raise exception 'Cart total exceeds checkout limit';end if;
 insert into gac_private.merch_orders(id,access_hash,client_hash,invoice,lines,subtotal_cents,shipping_cents,tax_cents,total_cents)
 values(p_id,p_access_hash,p_client_hash,'GAM'||left(replace(p_id::text,'-',''),17),lines,subtotal,shipping,tax,subtotal+shipping+tax)returning * into o;
 insert into gac_private.merch_order_holds select o.id,(x->>'id')::uuid,x->>'size',(x->>'quantity')::integer from jsonb_array_elements(lines)x;
 return jsonb_build_object('id',o.id,'invoice',o.invoice,'total_cents',o.total_cents,'subtotal_cents',o.subtotal_cents,'shipping_cents',o.shipping_cents,'tax_cents',o.tax_cents,'expires_at',o.expires_at);
end $$;

revoke all on function public.gac_begin_merch_checkout(uuid,text,text,jsonb)from public,anon,authenticated;
grant execute on function public.gac_begin_merch_checkout(uuid,text,text,jsonb)to service_role;

commit;
