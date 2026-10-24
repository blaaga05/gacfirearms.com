begin;
create table gac_private.merch_checkout_settings(singleton boolean primary key default true check(singleton),enabled boolean not null default false,shipping_cents integer not null default 0 check(shipping_cents between 0 and 100000),tax_bps integer not null default 0 check(tax_bps between 0 and 10000));
insert into gac_private.merch_checkout_settings(singleton)values(true);
create table gac_private.merch_orders(
 id uuid primary key,access_hash text not null check(access_hash~'^[a-f0-9]{64}$'),client_hash text not null,
 store_order_id uuid unique references public.gac_store_orders(id),
 invoice text not null unique check(invoice~'^GAM[a-f0-9]{17}$'),lines jsonb not null,subtotal_cents integer not null,shipping_cents integer not null,tax_cents integer not null,total_cents integer not null check(total_cents>0),
 state text not null default 'pending'check(state in('pending','review','paid','declined','voided','refund_pending','partially_refunded','refunded','cancelled')),
 created_at timestamptz not null default clock_timestamp(),expires_at timestamptz not null default clock_timestamp()+interval '20 minutes',payment_checked_at timestamptz,
 token text,token_claimed_at timestamptz,transaction_id text unique,submitted_at timestamptz,last_status text,note text,fulfilled_at timestamptz,stock_released_at timestamptz,
 email text,shipping jsonb not null default '{}'::jsonb
);
create table gac_private.merch_order_holds(order_id uuid not null references gac_private.merch_orders(id),product_id uuid not null references public.gac_merch_products(id),size text not null,quantity integer not null check(quantity between 1 and 99),primary key(order_id,product_id,size));
create index merch_order_holds_variant on gac_private.merch_order_holds(product_id,size);
create index merch_pending_expiry on gac_private.merch_orders(expires_at)where state='pending';
create table gac_private.merch_gateway_transactions(transaction_id text primary key,order_id uuid not null references gac_private.merch_orders(id),reference_transaction text,kind text not null,status text not null,amount_cents integer not null,observed_at timestamptz not null default clock_timestamp());
alter table gac_private.merch_orders enable row level security;alter table gac_private.merch_order_holds enable row level security;alter table gac_private.merch_gateway_transactions enable row level security;alter table gac_private.merch_checkout_settings enable row level security;
revoke all on gac_private.merch_orders,gac_private.merch_order_holds,gac_private.merch_gateway_transactions,gac_private.merch_checkout_settings from public,anon,authenticated;
alter table public.gac_store_orders alter column user_id drop not null;
create function public.gac_merch_checkout_available()returns boolean language plpgsql security definer set search_path=''as $$
begin
 if(select auth.role())is distinct from 'service_role'then raise exception 'Service access required';end if;
 return coalesce((select enabled from gac_private.merch_checkout_settings where singleton),false);
end $$;
revoke all on function public.gac_merch_checkout_available()from public,anon,authenticated;
grant execute on function public.gac_merch_checkout_available()to service_role;
create function gac_private.merch_available(p_product uuid,p_size text,p_except uuid default null)returns integer language sql stable security definer set search_path=''as $$
 select greatest(0,s.quantity-coalesce((select sum(h.quantity)from gac_private.merch_order_holds h join gac_private.merch_orders o on o.id=h.order_id where h.product_id=p_product and h.size=p_size and o.id is distinct from p_except and(o.state='review'or o.state='pending'and(o.expires_at>clock_timestamp()or o.token_claimed_at is not null and coalesce(o.payment_checked_at,'-infinity'::timestamptz)<o.expires_at))),0))::integer from public.gac_merch_stock s where s.product_id=p_product and s.size=p_size and s.quantity is not null;
$$;
revoke all on function gac_private.merch_available(uuid,text,uuid)from public,anon,authenticated;
create function public.gac_merch_availability()returns jsonb language sql stable security definer set search_path=''as $$
 select coalesce(jsonb_agg(jsonb_build_object('product_id',s.product_id,'size',s.size,'quantity',case when s.quantity is null then null else gac_private.merch_available(s.product_id,s.size)end)),'[]'::jsonb)from public.gac_merch_stock s join public.gac_merch_products p on p.id=s.product_id where p.published and s.size=any(p.sizes);
$$;
revoke all on function public.gac_merch_availability()from public;grant execute on function public.gac_merch_availability()to anon,authenticated;
create function public.gac_begin_merch_checkout(p_id uuid,p_access_hash text,p_client_hash text,p_cart jsonb)returns jsonb language plpgsql security definer set search_path=''as $$
declare o gac_private.merch_orders;p public.gac_merch_products;l jsonb;sn text;n integer;total integer:=0;lines jsonb:='[]';settings gac_private.merch_checkout_settings;
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
  total:=total+p.price_cents*n;lines:=lines||jsonb_build_array(jsonb_build_object('id',p.id,'name',p.name,'size',sn,'quantity',n,'unit_cents',p.price_cents));
 end loop;
 if total>1000000 then raise exception 'Cart total exceeds checkout limit';end if;
 insert into gac_private.merch_orders(id,access_hash,client_hash,invoice,lines,subtotal_cents,shipping_cents,tax_cents,total_cents)values(p_id,p_access_hash,p_client_hash,'GAM'||left(replace(p_id::text,'-',''),17),lines,total,settings.shipping_cents,round(total*settings.tax_bps/10000.0)::integer,total+settings.shipping_cents+round(total*settings.tax_bps/10000.0)::integer)returning * into o;
 insert into gac_private.merch_order_holds select o.id,(x->>'id')::uuid,x->>'size',(x->>'quantity')::integer from jsonb_array_elements(lines)x;
 return jsonb_build_object('id',o.id,'invoice',o.invoice,'total_cents',o.total_cents,'expires_at',o.expires_at);
end $$;
create function public.gac_merch_order_session(p_id uuid,p_access_hash text,p_token text default null)returns jsonb language plpgsql security definer set search_path=''as $$
declare o gac_private.merch_orders;
begin
 if(select auth.role())is distinct from 'service_role'then raise exception 'Service access required';end if;
 select * into strict o from gac_private.merch_orders where id=p_id and access_hash=p_access_hash for update;
 if p_token is not null then if o.state<>'pending'or o.expires_at<=clock_timestamp()or char_length(p_token)>10000 then raise exception 'Order cannot accept a token';end if;update gac_private.merch_orders set token=p_token where id=o.id;return '{}'::jsonb;end if;
 if o.state='pending'and o.expires_at>clock_timestamp()and o.token is null then
  if o.token_claimed_at>clock_timestamp()-interval '45 seconds'then raise exception 'Checkout is being prepared';end if;update gac_private.merch_orders set token_claimed_at=clock_timestamp()where id=o.id;
 end if;
 return jsonb_build_object('id',o.id,'invoice',o.invoice,'state',case when o.state='pending'and o.expires_at<=clock_timestamp()then 'expired'else o.state end,'total_cents',o.total_cents,'subtotal_cents',o.subtotal_cents,'shipping_cents',o.shipping_cents,'tax_cents',o.tax_cents,'expires_at',o.expires_at,'lines',o.lines,'transaction',o.transaction_id,'token',case when o.state='pending'and o.expires_at>clock_timestamp()then o.token else null end,'note',o.note);
end $$;
create function public.gac_cancel_merch_order(p_id uuid,p_access_hash text)returns void language plpgsql security definer set search_path=''as $$
begin
 if(select auth.role())is distinct from 'service_role'then raise exception 'Service access required';end if;
 -- A hosted form may still accept payment. Opened sessions remain gated until gateway-checked expiry.
 update gac_private.merch_orders set state='cancelled'where id=p_id and access_hash=p_access_hash and state='pending'and token_claimed_at is null;
end $$;
alter table gac_private.merch_stock_events alter column actor drop not null;
alter table gac_private.merch_stock_events add column order_id uuid references gac_private.merch_orders(id);
create function public.gac_apply_merch_gateway(p_transaction text,p_invoice text,p_reference text,p_kind text,p_status text,p_amount_cents integer,p_submitted timestamptz,p_approved boolean,p_email text,p_shipping jsonb)returns text language plpgsql security definer set search_path=''as $$
declare o gac_private.merch_orders;l jsonb;s public.gac_merch_stock;refunded bigint;refund_pending bigint;next_state text;
begin
 if(select auth.role())is distinct from 'service_role'then raise exception 'Service access required';end if;
 if p_transaction!~'^[0-9]{1,30}$'or p_amount_cents<0 then raise exception 'Invalid gateway observation';end if;
 select * into o from gac_private.merch_orders where invoice=p_invoice or transaction_id=p_reference order by created_at limit 1 for update;if not found then return 'unrelated';end if;
 if exists(select 1 from gac_private.merch_gateway_transactions where transaction_id=p_transaction and order_id<>o.id)then raise exception 'Transaction already belongs to another order';end if;
 insert into gac_private.merch_gateway_transactions(transaction_id,order_id,reference_transaction,kind,status,amount_cents)values(p_transaction,o.id,p_reference,p_kind,p_status,p_amount_cents)on conflict(transaction_id)do update set status=excluded.status,amount_cents=excluded.amount_cents,observed_at=clock_timestamp();
 if p_kind='refundTransaction'then
  select coalesce(sum(amount_cents)filter(where status='refundSettledSuccessfully'),0),coalesce(sum(amount_cents)filter(where status='refundPendingSettlement'),0)into refunded,refund_pending from gac_private.merch_gateway_transactions where order_id=o.id and kind='refundTransaction';
  next_state:=case when refunded>=o.total_cents then 'refunded'when refund_pending>0 then 'refund_pending'when refunded>0 then 'partially_refunded'else o.state end;
  update gac_private.merch_orders set state=next_state,note='Refund recorded. Returned merchandise must be checked before manual restocking.'where id=o.id;
  if next_state in('partially_refunded','refunded')and o.store_order_id is not null then update public.gac_store_orders set payment_status=next_state where id=o.store_order_id;end if;
  return 'review';
 end if;
 if p_kind<>'authCaptureTransaction'then return 'ignored';end if;
 if o.transaction_id is not null and o.transaction_id<>p_transaction then update gac_private.merch_orders set note='Another payment was received for this order. GAC review required.'where id=o.id;return 'review';end if;
 if p_status in('voided','declined','expired','failedReview')then update gac_private.merch_orders set state=case when p_status='voided'then 'voided'else 'declined'end,last_status=p_status,transaction_id=case when p_status='voided'then coalesce(transaction_id,p_transaction)else transaction_id end,token=null,note=case when fulfilled_at is not null then 'Payment reversed. Owner must review stock and any shipment.'else 'Payment was not completed. No merchandise was fulfilled.'end where id=o.id;return 'voided';end if;
 if o.fulfilled_at is not null then return 'credited';end if;
 if o.state in('voided','refunded','refund_pending','partially_refunded','cancelled')then return 'review';end if;
 if p_amount_cents<>o.total_cents or p_submitted is null or p_submitted<o.created_at-interval '1 minute'or p_submitted>clock_timestamp()+interval '1 minute'then update gac_private.merch_orders set state='review',note='Payment amount or timestamp mismatch. Do not pay again.'where id=o.id;return 'review';end if;
 if p_status in('FDSPendingReview','FDSAuthorizedPendingReview')then update gac_private.merch_orders set state='review',last_status=p_status,transaction_id=p_transaction,submitted_at=p_submitted,note='Payment awaiting merchant approval. Stock remains protected; no shipment is authorized.'where id=o.id;return 'protected';end if;
 if not p_approved or p_status not in('capturedPendingSettlement','settledSuccessfully')then return 'ignored';end if;
 update gac_private.merch_orders set state='review',transaction_id=p_transaction,submitted_at=p_submitted,last_status=p_status,token=null where id=o.id;
 for l in select x from jsonb_array_elements(o.lines)x order by x->>'id',x->>'size'loop
  perform 1 from public.gac_merch_products where id=(l->>'id')::uuid for update;
  select * into strict s from public.gac_merch_stock where product_id=(l->>'id')::uuid and size=l->>'size'for update;
  if coalesce(gac_private.merch_available(s.product_id,s.size,o.id),-1)<(l->>'quantity')::integer then update gac_private.merch_orders set note='Payment received, but stock is no longer available. Contact GAC; do not pay again.'where id=o.id;return 'review';end if;
 end loop;
 if coalesce(p_shipping->>'address1','')=''or coalesce(p_shipping->>'postal_code','')=''or coalesce(p_email,'')=''then update gac_private.merch_orders set state='review',transaction_id=p_transaction,submitted_at=p_submitted,last_status=p_status,note='Payment received. GAC needs complete shipping information before fulfillment.'where id=o.id;return 'review';end if;
 -- Under the order/product/variant locks, consume all lines exactly once.
 delete from gac_private.merch_order_holds where order_id=o.id;
 for l in select x from jsonb_array_elements(o.lines)x order by x->>'id',x->>'size'loop
  select * into strict s from public.gac_merch_stock where product_id=(l->>'id')::uuid and size=l->>'size'for update;
  update public.gac_merch_stock set quantity=quantity-(l->>'quantity')::integer,revision=revision+1,updated_at=clock_timestamp()where product_id=s.product_id and size=s.size;
  insert into gac_private.merch_stock_events(request_id,product_id,size,actor,action,units,previous_quantity,new_quantity,note,order_id)values(extensions.gen_random_uuid(),s.product_id,s.size,null,'sale',(l->>'quantity')::integer,s.quantity,s.quantity-(l->>'quantity')::integer,'Verified online merchandise payment',o.id);
 end loop;
 insert into public.gac_store_orders(order_number,user_id,customer_email,items,subtotal_cents,shipping_cents,tax_cents,total_cents,currency,payment_reference,payment_status,fulfillment_status,shipping_address)
 values(o.invoice,null,left(p_email,254),o.lines,o.subtotal_cents,o.shipping_cents,o.tax_cents,o.total_cents,'USD',p_transaction,'paid','pending_fulfillment',jsonb_build_object('name',p_shipping->>'name','address1',p_shipping->>'address1','city',p_shipping->>'city','state',p_shipping->>'state','postal_code',p_shipping->>'postal_code','country',p_shipping->>'country'))
 on conflict(order_number)do nothing returning id into o.store_order_id;
 if o.store_order_id is null then select id into o.store_order_id from public.gac_store_orders where order_number=o.invoice;end if;
 if o.store_order_id is null then raise exception 'Paid merchandise order record could not be created';end if;
 update gac_private.merch_orders set state='paid',store_order_id=o.store_order_id,fulfilled_at=clock_timestamp(),email=left(p_email,254),shipping=p_shipping,note=null where id=o.id;return 'credited';
end $$;
create function public.gac_owner_merch_orders()returns jsonb language plpgsql stable security definer set search_path=''as $$
begin
 if auth.uid()is null or not public.gac_is_owner()then raise exception 'Owner access required'using errcode='42501';end if;
 return(select coalesce(jsonb_agg(x),'[]'::jsonb)from(select id,invoice,lines,total_cents,state,created_at,expires_at,transaction_id,last_status,note,email,shipping,fulfilled_at from gac_private.merch_orders order by created_at desc limit 100)x);
end $$;
create function public.gac_owner_merch_checkout_settings(p_shipping_cents integer,p_tax_bps integer)returns jsonb language plpgsql security definer set search_path=''as $$
declare s gac_private.merch_checkout_settings;
begin
 if auth.uid()is null or not public.gac_is_owner()then raise exception 'Owner access required'using errcode='42501';end if;
 if p_shipping_cents is null and p_tax_bps is null then select * into strict s from gac_private.merch_checkout_settings where singleton;return jsonb_build_object('enabled',s.enabled,'shipping_cents',s.shipping_cents,'tax_bps',s.tax_bps);end if;
 if p_shipping_cents is null or p_tax_bps is null or p_shipping_cents not between 0 and 100000 or p_tax_bps not between 0 and 10000 then raise exception 'Shipping and tax settings are outside supported limits';end if;
 update gac_private.merch_checkout_settings set shipping_cents=p_shipping_cents,tax_bps=p_tax_bps,enabled=false where singleton returning * into s;
 return jsonb_build_object('enabled',s.enabled,'shipping_cents',s.shipping_cents,'tax_bps',s.tax_bps);
end $$;
create function public.gac_owner_merch_checkout(p_enabled boolean default null)returns boolean language plpgsql security definer set search_path=''as $$
begin
 if auth.uid()is null or not public.gac_is_owner()then raise exception 'Owner access required'using errcode='42501';end if;
 if p_enabled is true then raise exception 'Paid merchandise checkout remains disabled until release checks are complete';end if;
 if p_enabled is false then update gac_private.merch_checkout_settings set enabled=false where singleton;end if;
 return false;
end $$;
revoke all on function public.gac_begin_merch_checkout(uuid,text,text,jsonb),public.gac_merch_order_session(uuid,text,text),public.gac_cancel_merch_order(uuid,text),public.gac_apply_merch_gateway(text,text,text,text,text,integer,timestamptz,boolean,text,jsonb)from public,anon,authenticated;
grant execute on function public.gac_begin_merch_checkout(uuid,text,text,jsonb),public.gac_merch_order_session(uuid,text,text),public.gac_cancel_merch_order(uuid,text),public.gac_apply_merch_gateway(text,text,text,text,text,integer,timestamptz,boolean,text,jsonb)to service_role;
revoke all on function public.gac_owner_merch_orders(),public.gac_owner_merch_checkout(boolean)from public,anon,authenticated;
grant execute on function public.gac_owner_merch_orders(),public.gac_owner_merch_checkout(boolean)to authenticated;
revoke all on function public.gac_owner_merch_checkout_settings(integer,integer)from public,anon;
grant execute on function public.gac_owner_merch_checkout_settings(integer,integer)to authenticated;
create function gac_private.guard_merch_reserved_stock()returns trigger language plpgsql security definer set search_path=''as $$
declare reserved bigint;
begin
 select coalesce(sum(h.quantity),0)into reserved from gac_private.merch_order_holds h join gac_private.merch_orders o on o.id=h.order_id where h.product_id=new.product_id and h.size=new.size and(o.state='review'or o.state='pending'and(o.expires_at>clock_timestamp()or o.token_claimed_at is not null and coalesce(o.payment_checked_at,'-infinity'::timestamptz)<o.expires_at));
 if new.quantity is null and reserved>0 or new.quantity<reserved then raise exception 'Stock is reserved for an open payment. Resolve the order before reducing this count';end if;return new;
end $$;
revoke all on function gac_private.guard_merch_reserved_stock()from public,anon,authenticated;
create trigger guard_merch_stock_reservations before update of quantity on public.gac_merch_stock for each row execute function gac_private.guard_merch_reserved_stock();

create or replace function public.gac_enqueue_payment_recovery(p_candidates jsonb) returns integer language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 if (select auth.role()) is distinct from 'service_role' then raise exception 'Service access required';end if;
 if jsonb_typeof(p_candidates)<>'array' or jsonb_array_length(p_candidates)>1000 then raise exception 'Invalid recovery page';end if;
 insert into gac_private.payment_recovery_queue(transaction_id)
 select distinct x->>'id' from jsonb_array_elements(p_candidates)x where x->>'id'~'^[0-9]{1,30}$' and (exists(select 1 from gac_private.authorizenet_checkouts i where i.invoice=x->>'invoice') or exists(select 1 from gac_private.merch_orders m where m.invoice=x->>'invoice') or exists(select 1 from gac_private.payment_recovery_queue q where q.transaction_id=x->>'id') or x->>'status' in('refundPendingSettlement','refundSettledSuccessfully')) on conflict(transaction_id) do nothing;
 get diagnostics n=row_count;return n;
end $$;

create or replace function public.gac_expired_unchecked_checkouts()returns jsonb language plpgsql security definer set search_path=''as $$
begin
 if(select auth.role())is distinct from 'service_role'then raise exception 'Service access required';end if;
 return(select coalesce(jsonb_agg(x),'[]'::jsonb)from(select i.id,i.invoice,i.expires_at from gac_private.authorizenet_checkouts i where i.token_claimed_at is not null and i.order_id is null and i.expires_at<=clock_timestamp()and coalesce(i.payment_checked_at,'-infinity'::timestamptz)<i.expires_at and not exists(select 1 from gac_private.payment_allocations a where a.checkout_id=i.id)union all select m.id,m.invoice,m.expires_at from gac_private.merch_orders m where m.state='pending'and m.token_claimed_at is not null and m.expires_at<=clock_timestamp()and coalesce(m.payment_checked_at,'-infinity'::timestamptz)<m.expires_at order by expires_at limit 20)x);
end $$;
create or replace function public.gac_mark_payment_expiry_checked(p_checkouts uuid[],p_checked_at timestamptz)returns void language plpgsql security definer set search_path=''as $$
begin
 if(select auth.role())is distinct from 'service_role'then raise exception 'Service access required';end if;
 if p_checked_at>clock_timestamp()or p_checked_at<clock_timestamp()-interval '2 minutes'then raise exception 'Invalid payment check time';end if;
 update gac_private.authorizenet_checkouts set payment_checked_at=p_checked_at where id=any(p_checkouts)and expires_at<=p_checked_at;
 update gac_private.merch_orders set payment_checked_at=p_checked_at where id=any(p_checkouts)and expires_at<=p_checked_at;
end $$;

create or replace function gac_private.invoke_payment_expiry()returns bigint language plpgsql security definer set search_path=''as $$
declare endpoint text;token text;request_id bigint;
begin
 if not exists(select 1 from gac_private.authorizenet_checkouts i where i.token_claimed_at is not null and i.order_id is null and i.expires_at<=clock_timestamp()and coalesce(i.payment_checked_at,'-infinity'::timestamptz)<i.expires_at and not exists(select 1 from gac_private.payment_allocations a where a.checkout_id=i.id))and not exists(select 1 from gac_private.merch_orders m where m.state='pending'and m.token_claimed_at is not null and m.expires_at<=clock_timestamp()and coalesce(m.payment_checked_at,'-infinity'::timestamptz)<m.expires_at)then return null;end if;
 select replace(s.endpoint,'gac-payment-recovery','gac-payment-expiry')into strict endpoint from gac_private.payment_recovery_state s where singleton;
 select decrypted_secret into strict token from vault.decrypted_secrets where name='gac_payment_recovery_token';
 select net.http_post(url:=endpoint,headers:=jsonb_build_object('Content-Type','application/json','x-gac-recovery-token',token),body:='{}'::jsonb,timeout_milliseconds:=100000)into request_id;return request_id;
end $$;

commit;
