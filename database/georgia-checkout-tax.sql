begin;

-- The per-product tax field is no longer used for checkout. Tax is computed
-- once for the shipping destination using the current Georgia DOR rate chart.
alter table gac_private.merch_orders
 add column if not exists tax_rate_bps integer not null default 0 check(tax_rate_bps between 0 and 1000),
 add column if not exists tax_jurisdiction text;

drop function if exists public.gac_begin_merch_checkout(uuid,text,text,jsonb);
drop function if exists public.gac_begin_merch_checkout(uuid,text,text,jsonb,jsonb,integer);
create function public.gac_begin_merch_checkout(
 p_id uuid,p_access_hash text,p_client_hash text,p_cart jsonb,p_shipping jsonb,p_tax_bps integer
)returns jsonb language plpgsql security definer set search_path=''as $$
declare o gac_private.merch_orders;p public.gac_merch_products;l jsonb;sn text;n integer;subtotal integer:=0;shipping_total integer:=0;tax integer:=0;lines jsonb:='[]';settings gac_private.merch_checkout_settings;state_code text;rate_jurisdiction text;
begin
 if(select auth.role())is distinct from 'service_role'then raise exception 'Service access required';end if;
 select * into strict settings from gac_private.merch_checkout_settings where singleton for update;
 if not settings.enabled then raise exception 'Merchandise checkout is temporarily unavailable';end if;
 if p_id is null or p_access_hash is null or p_client_hash is null or p_cart is null or jsonb_typeof(p_cart)<>'array' or jsonb_array_length(p_cart)not between 1 and 10 or p_access_hash!~'^[a-f0-9]{64}$' or p_client_hash!~'^[a-f0-9]{64}$' then raise exception 'Invalid cart';end if;
 if p_shipping is null or jsonb_typeof(p_shipping)<>'object' or coalesce(btrim(p_shipping->>'name'),'')='' or coalesce(btrim(p_shipping->>'address1'),'')='' or coalesce(btrim(p_shipping->>'city'),'')='' or coalesce(p_shipping->>'country','')<>'US' or coalesce(p_shipping->>'state','')!~'^[A-Z]{2}$' or coalesce(btrim(p_shipping->>'postal_code'),'')='' then raise exception 'Enter a complete US delivery address';end if;
 state_code:=p_shipping->>'state';
 if state_code='GA' then
  if coalesce(btrim(p_shipping->>'county'),'')='' or p_tax_bps not between 390 and 900 then raise exception 'Choose a Georgia county and valid destination rate';end if;
  rate_jurisdiction:=coalesce(nullif(p_shipping->>'tax_jurisdiction',''),p_shipping->>'county');
 elsif p_tax_bps<>0 then raise exception 'Out-of-state orders must not collect Georgia sales tax';
 else rate_jurisdiction:=null;
 end if;
 p_shipping:=p_shipping||jsonb_build_object('tax_rate_bps',p_tax_bps,'tax_jurisdiction',rate_jurisdiction,'tax_effective_from','2026-10-01','tax_effective_through','2026-12-31','tax_rate_source','Georgia DOR General Rate Chart');

 select * into o from gac_private.merch_orders where id=p_id for update;
 if found then
  if o.access_hash<>p_access_hash then raise exception 'Invalid order access';end if;
  if o.shipping<>p_shipping then raise exception 'Delivery details changed. Start a fresh checkout';end if;
  if o.state<>'pending'or o.expires_at<=clock_timestamp()then raise exception 'Checkout expired or already processed. Start a fresh checkout';end if;
  return jsonb_build_object('id',o.id,'invoice',o.invoice,'total_cents',o.total_cents,'subtotal_cents',o.subtotal_cents,'shipping_cents',o.shipping_cents,'tax_cents',o.tax_cents,'tax_rate_bps',o.tax_rate_bps,'tax_jurisdiction',o.tax_jurisdiction,'expires_at',o.expires_at);
 end if;
 if(select count(*)from gac_private.merch_orders where client_hash=p_client_hash and created_at>clock_timestamp()-interval '1 hour')>=10 or(select count(*)from gac_private.merch_orders where state='pending'and expires_at>clock_timestamp())>=30 then raise exception 'Too many checkout attempts. Try again later';end if;
 if(select count(distinct(x->>'id',x->>'size'))from jsonb_array_elements(p_cart)x)<>jsonb_array_length(p_cart)then raise exception 'Combine duplicate cart lines';end if;
 for l in select x from jsonb_array_elements(p_cart)x order by x->>'id',x->>'size' loop
  if coalesce(l->>'quantity','')!~'^[1-9][0-9]?$'then raise exception 'Choose whole quantities from 1 to 99';end if;n:=(l->>'quantity')::integer;sn:=l->>'size';
  select * into strict p from public.gac_merch_products where id=(l->>'id')::uuid for update;
  if not p.published or p.price_pending or not sn=any(p.sizes)then raise exception 'An item is unavailable or awaiting a price';end if;
  perform 1 from public.gac_merch_stock where product_id=p.id and size=sn for update;
  if coalesce(gac_private.merch_available(p.id,sn),-1)<n then raise exception 'Not enough stock for % (%)',p.name,sn;end if;
  subtotal:=subtotal+p.price_cents*n;shipping_total:=shipping_total+p.shipping_cents*n;
  lines:=lines||jsonb_build_array(jsonb_build_object('id',p.id,'name',p.name,'size',sn,'quantity',n,'unit_cents',p.price_cents,'shipping_unit_cents',p.shipping_cents,'image_path',p.image_path));
 end loop;
 tax:=round((subtotal+shipping_total)*p_tax_bps/10000.0)::integer;
 if subtotal+shipping_total+tax>1000000 then raise exception 'Cart total exceeds checkout limit';end if;
 insert into gac_private.merch_orders(id,access_hash,client_hash,invoice,lines,subtotal_cents,shipping_cents,tax_cents,total_cents,shipping,tax_rate_bps,tax_jurisdiction)
 values(p_id,p_access_hash,p_client_hash,'GAM'||left(replace(p_id::text,'-',''),17),lines,subtotal,shipping_total,tax,subtotal+shipping_total+tax,p_shipping,p_tax_bps,rate_jurisdiction)returning * into o;
 insert into gac_private.merch_order_holds select o.id,(x->>'id')::uuid,x->>'size',(x->>'quantity')::integer from jsonb_array_elements(lines)x;
 return jsonb_build_object('id',o.id,'invoice',o.invoice,'total_cents',o.total_cents,'subtotal_cents',o.subtotal_cents,'shipping_cents',o.shipping_cents,'tax_cents',o.tax_cents,'tax_rate_bps',o.tax_rate_bps,'tax_jurisdiction',o.tax_jurisdiction,'expires_at',o.expires_at);
end $$;
revoke all on function public.gac_begin_merch_checkout(uuid,text,text,jsonb,jsonb,integer)from public,anon,authenticated;
grant execute on function public.gac_begin_merch_checkout(uuid,text,text,jsonb,jsonb,integer)to service_role;

create or replace function public.gac_merch_order_session(p_id uuid,p_access_hash text,p_token text default null)returns jsonb language plpgsql security definer set search_path=''as $$
declare o gac_private.merch_orders;
begin
 if(select auth.role())is distinct from 'service_role'then raise exception 'Service access required';end if;
 select * into strict o from gac_private.merch_orders where id=p_id and access_hash=p_access_hash for update;
 if p_token is not null then if o.state<>'pending'or o.expires_at<=clock_timestamp()or char_length(p_token)>10000 then raise exception 'Order cannot accept a token';end if;update gac_private.merch_orders set token=p_token where id=o.id;return '{}'::jsonb;end if;
 if o.state='pending'and o.expires_at>clock_timestamp()and o.token is null then if o.token_claimed_at>clock_timestamp()-interval '45 seconds'then raise exception 'Checkout is being prepared';end if;update gac_private.merch_orders set token_claimed_at=clock_timestamp()where id=o.id;end if;
 return jsonb_build_object('id',o.id,'invoice',o.invoice,'state',case when o.state='pending'and o.expires_at<=clock_timestamp()then 'expired'else o.state end,'total_cents',o.total_cents,'subtotal_cents',o.subtotal_cents,'shipping_cents',o.shipping_cents,'tax_cents',o.tax_cents,'tax_rate_bps',o.tax_rate_bps,'tax_jurisdiction',o.tax_jurisdiction,'expires_at',o.expires_at,'lines',o.lines,'transaction',o.transaction_id,'token',case when o.state='pending'and o.expires_at>clock_timestamp()then o.token else null end,'note',o.note);
end $$;

create or replace function public.gac_owner_merch_orders()returns jsonb language plpgsql stable security definer set search_path=''as $$
begin
 if auth.uid()is null or not public.gac_is_owner()then raise exception 'Owner access required'using errcode='42501';end if;
 return(select coalesce(jsonb_agg(x),'[]'::jsonb)from(select id,invoice,lines,subtotal_cents,shipping_cents,tax_cents,total_cents,tax_rate_bps,tax_jurisdiction,state,created_at,expires_at,transaction_id,last_status,note,email,shipping,fulfilled_at from gac_private.merch_orders order by created_at desc limit 100)x);
end $$;

create or replace function public.gac_merch_shipping_for_invoice(p_invoice text)returns jsonb language plpgsql stable security definer set search_path=''as $$
begin
 if(select auth.role())is distinct from 'service_role'then raise exception 'Service access required';end if;
 return(select shipping from gac_private.merch_orders where invoice=p_invoice limit 1);
end $$;
revoke all on function public.gac_merch_shipping_for_invoice(text)from public,anon,authenticated;
grant execute on function public.gac_merch_shipping_for_invoice(text)to service_role;

create or replace function gac_private.add_merch_tax_address()returns trigger language plpgsql security definer set search_path=''as $$
declare destination jsonb;
begin
 if new.order_number~'^GAM[a-f0-9]{17}$'then
  select shipping into destination from gac_private.merch_orders where invoice=new.order_number;
  if destination is not null then new.shipping_address:=coalesce(new.shipping_address,'{}'::jsonb)||jsonb_build_object('county',destination->>'county','tax_jurisdiction',destination->>'tax_jurisdiction','tax_rate_bps',destination->>'tax_rate_bps','tax_effective_from',destination->>'tax_effective_from','tax_effective_through',destination->>'tax_effective_through');end if;
 end if;
 return new;
end $$;
revoke all on function gac_private.add_merch_tax_address()from public,anon,authenticated;
drop trigger if exists add_merch_tax_address on public.gac_store_orders;
create trigger add_merch_tax_address before insert on public.gac_store_orders for each row execute function gac_private.add_merch_tax_address();

notify pgrst,'reload schema';
commit;
