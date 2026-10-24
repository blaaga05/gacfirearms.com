begin;

-- Link optional member checkout identity to the private checkout record.
alter table gac_private.merch_orders
  add column if not exists user_id uuid references auth.users(id) on delete set null;

create or replace function public.gac_attach_merch_customer(
  p_id uuid,
  p_access_hash text,
  p_user_id uuid
) returns void
language plpgsql security definer set search_path=''
as $$
declare o gac_private.merch_orders;
begin
  if (select auth.role()) is distinct from 'service_role' then
    raise exception 'Service access required';
  end if;
  if p_user_id is null or p_access_hash !~ '^[a-f0-9]{64}$' then
    raise exception 'Invalid customer link';
  end if;
  select * into strict o
  from gac_private.merch_orders
  where id=p_id and access_hash=p_access_hash
  for update;
  if o.state <> 'pending' or o.expires_at <= clock_timestamp() then
    raise exception 'Checkout expired or already processed';
  end if;
  if o.user_id is not null and o.user_id <> p_user_id then
    raise exception 'Checkout is already linked to another account';
  end if;
  update gac_private.merch_orders set user_id=p_user_id where id=o.id;
end;
$$;
revoke all on function public.gac_attach_merch_customer(uuid,text,uuid)
  from public,anon,authenticated;
grant execute on function public.gac_attach_merch_customer(uuid,text,uuid)
  to service_role;

-- Keep the customer order's item snapshot self-contained for future order history.
create or replace function public.gac_begin_merch_checkout(
  p_id uuid,p_access_hash text,p_client_hash text,p_cart jsonb
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  o gac_private.merch_orders;
  p public.gac_merch_products;
  l jsonb;
  sn text;
  n integer;
  total integer:=0;
  lines jsonb:='[]';
  settings gac_private.merch_checkout_settings;
begin
  if (select auth.role()) is distinct from 'service_role' then raise exception 'Service access required'; end if;
  select * into strict settings from gac_private.merch_checkout_settings where singleton for update;
  if not settings.enabled then raise exception 'Merchandise checkout is temporarily unavailable'; end if;
  if p_id is null or p_access_hash is null or p_client_hash is null or p_cart is null or p_access_hash !~ '^[a-f0-9]{64}$' or p_client_hash !~ '^[a-f0-9]{64}$' or jsonb_typeof(p_cart)<>'array' or jsonb_array_length(p_cart) not between 1 and 10 then raise exception 'Invalid cart'; end if;
  select * into o from gac_private.merch_orders where id=p_id for update;
  if found then
    if o.access_hash<>p_access_hash then raise exception 'Invalid order access'; end if;
    if o.state<>'pending' or o.expires_at<=clock_timestamp() then raise exception 'Checkout expired or already processed. Start a fresh checkout'; end if;
    return jsonb_build_object('id',o.id,'invoice',o.invoice,'total_cents',o.total_cents,'expires_at',o.expires_at);
  end if;
  if (select count(*) from gac_private.merch_orders where client_hash=p_client_hash and created_at>clock_timestamp()-interval '1 hour')>=10 or (select count(*) from gac_private.merch_orders where state='pending' and expires_at>clock_timestamp())>=30 then raise exception 'Too many checkout attempts. Try again later'; end if;
  if (select count(distinct(x->>'id',x->>'size')) from jsonb_array_elements(p_cart)x)<>jsonb_array_length(p_cart) then raise exception 'Combine duplicate cart lines'; end if;
  for l in select x from jsonb_array_elements(p_cart)x order by x->>'id',x->>'size' loop
    if coalesce(l->>'quantity','') !~ '^[1-9][0-9]?$' then raise exception 'Choose whole quantities from 1 to 99'; end if;
    n:=(l->>'quantity')::integer; sn:=l->>'size';
    select * into strict p from public.gac_merch_products where id=(l->>'id')::uuid for update;
    if not p.published or p.price_pending or not sn=any(p.sizes) then raise exception 'An item is unavailable or awaiting a price'; end if;
    perform 1 from public.gac_merch_stock where product_id=p.id and size=sn for update;
    if coalesce(gac_private.merch_available(p.id,sn),-1)<n then raise exception 'Not enough stock for % (%)',p.name,sn; end if;
    total:=total+p.price_cents*n;
    lines:=lines||jsonb_build_array(jsonb_build_object('id',p.id,'name',p.name,'size',sn,'quantity',n,'unit_cents',p.price_cents,'image_path',p.image_path));
  end loop;
  if total>1000000 then raise exception 'Cart total exceeds checkout limit'; end if;
  insert into gac_private.merch_orders(id,access_hash,client_hash,invoice,lines,subtotal_cents,shipping_cents,tax_cents,total_cents)
    values(p_id,p_access_hash,p_client_hash,'GAM'||left(replace(p_id::text,'-',''),17),lines,total,settings.shipping_cents,round(total*settings.tax_bps/10000.0)::integer,total+settings.shipping_cents+round(total*settings.tax_bps/10000.0)::integer)
    returning * into o;
  insert into gac_private.merch_order_holds select o.id,(x->>'id')::uuid,x->>'size',(x->>'quantity')::integer from jsonb_array_elements(lines)x;
  return jsonb_build_object('id',o.id,'invoice',o.invoice,'total_cents',o.total_cents,'expires_at',o.expires_at);
end;
$$;
revoke all on function public.gac_begin_merch_checkout(uuid,text,text,jsonb)
  from public,anon,authenticated;
grant execute on function public.gac_begin_merch_checkout(uuid,text,text,jsonb)
  to service_role;

-- Attach signed-in merchandise orders to the existing member-readable order row.
create or replace function gac_private.link_merch_store_order_customer()
returns trigger language plpgsql security definer set search_path=''
as $$
declare member_id uuid;
begin
  select user_id into member_id from gac_private.merch_orders where invoice=new.order_number;
  if member_id is not null then
    update public.gac_store_orders set user_id=member_id where id=new.id and user_id is null;
  end if;
  return new;
end;
$$;
revoke all on function gac_private.link_merch_store_order_customer()
  from public,anon,authenticated;
drop trigger if exists link_merch_store_order_customer on public.gac_store_orders;
create trigger link_merch_store_order_customer
  after insert on public.gac_store_orders
  for each row execute function gac_private.link_merch_store_order_customer();

-- A view marker is private and follows the member across devices.
create table if not exists gac_private.gac_store_order_views(
  user_id uuid not null references auth.users(id) on delete cascade,
  order_id uuid not null references public.gac_store_orders(id) on delete cascade,
  last_seen_updated_at timestamptz not null,
  primary key(user_id,order_id)
);
alter table gac_private.gac_store_order_views enable row level security;
revoke all on gac_private.gac_store_order_views from public,anon,authenticated;
create index if not exists gac_store_order_views_order_idx
  on gac_private.gac_store_order_views(order_id);

-- Existing orders start as read so the new feature only signals future updates.
insert into gac_private.gac_store_order_views(user_id,order_id,last_seen_updated_at)
select user_id,id,updated_at from public.gac_store_orders where user_id is not null
on conflict(user_id,order_id) do nothing;

create or replace function public.gac_customer_order_update_count()
returns integer language plpgsql stable security definer set search_path=''
as $$
begin
  if auth.uid() is null or not public.gac_is_member() then
    raise exception 'Member access required' using errcode='42501';
  end if;
  return (select count(*)::integer
    from public.gac_store_orders o
    left join gac_private.gac_store_order_views v
      on v.user_id=auth.uid() and v.order_id=o.id
    where o.user_id=auth.uid()
      and (v.order_id is null or o.updated_at>v.last_seen_updated_at));
end;
$$;
revoke all on function public.gac_customer_order_update_count() from public,anon;
grant execute on function public.gac_customer_order_update_count() to authenticated;

create or replace function public.gac_mark_customer_order_updates_seen()
returns void language plpgsql security definer set search_path=''
as $$
begin
  if auth.uid() is null or not public.gac_is_member() then
    raise exception 'Member access required' using errcode='42501';
  end if;
  insert into gac_private.gac_store_order_views(user_id,order_id,last_seen_updated_at)
  select auth.uid(),id,updated_at from public.gac_store_orders where user_id=auth.uid()
  on conflict(user_id,order_id) do update
    set last_seen_updated_at=excluded.last_seen_updated_at;
end;
$$;
revoke all on function public.gac_mark_customer_order_updates_seen() from public,anon;
grant execute on function public.gac_mark_customer_order_updates_seen() to authenticated;

create or replace function gac_private.bump_gac_store_order_updated_at()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  new.updated_at:=greatest(clock_timestamp(),old.updated_at+interval '1 microsecond');
  return new;
end;
$$;
revoke all on function gac_private.bump_gac_store_order_updated_at() from public,anon,authenticated;
drop trigger if exists bump_gac_store_order_updated_at on public.gac_store_orders;
create trigger bump_gac_store_order_updated_at
  before update on public.gac_store_orders
  for each row execute function gac_private.bump_gac_store_order_updated_at();

commit;
