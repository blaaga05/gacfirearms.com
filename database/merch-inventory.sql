begin;
create table public.gac_merch_stock(
 product_id uuid not null references public.gac_merch_products(id) on delete cascade,
 size text not null,
 quantity integer check(quantity between 0 and 1000000),
 revision bigint not null default 0,
 updated_at timestamptz not null default now(),
 primary key(product_id,size)
);
alter table public.gac_merch_stock enable row level security;
revoke all on public.gac_merch_stock from public,anon,authenticated;
grant select on public.gac_merch_stock to anon,authenticated;
create policy stock_public_read on public.gac_merch_stock for select to anon using(exists(select 1 from public.gac_merch_products p where p.id=product_id and size=any(p.sizes) and p.published));
create policy stock_member_read on public.gac_merch_stock for select to authenticated using(exists(select 1 from public.gac_merch_products p where p.id=product_id and size=any(p.sizes) and p.published)or(select public.gac_is_owner()));
create table gac_private.merch_stock_events(
 request_id uuid primary key,
 product_id uuid not null references public.gac_merch_products(id),
 size text not null,actor uuid not null,
 action text not null check(action in('count','receive','sale','adjustment')),
 units integer not null,
 previous_quantity integer,
 new_quantity integer not null,
 note text not null check(char_length(note) between 1 and 300),
 created_at timestamptz not null default now()
);
alter table gac_private.merch_stock_events enable row level security;
revoke all on gac_private.merch_stock_events from public,anon,authenticated;
create index merch_stock_events_product_time on gac_private.merch_stock_events(product_id,created_at desc);
create function gac_private.sync_merch_stock() returns trigger language plpgsql security definer set search_path=''as $$
begin
 insert into public.gac_merch_stock(product_id,size)select new.id,s from unnest(new.sizes)s on conflict do nothing;return new;
end $$;
revoke all on function gac_private.sync_merch_stock()from public,anon,authenticated;
create trigger merch_stock_variants after insert or update of sizes on public.gac_merch_products for each row execute function gac_private.sync_merch_stock();
insert into public.gac_merch_stock(product_id,size) select p.id,s from public.gac_merch_products p cross join lateral unnest(p.sizes)s on conflict do nothing;
create function public.gac_owner_change_merch_stock(p_product uuid,p_size text,p_action text,p_units integer,p_revision bigint,p_note text,p_request uuid)returns jsonb language plpgsql security definer set search_path=''as $$
declare s public.gac_merch_stock;e gac_private.merch_stock_events;n integer;before_quantity integer;
begin
 if auth.uid()is null or not public.gac_is_owner()then raise exception 'Owner access required'using errcode='42501';end if;
 if p_request is null or p_note is null or char_length(trim(p_note))not between 1 and 300 or p_action is null or p_action not in('count','receive','sale','adjustment')or p_units is null then raise exception 'Enter a valid stock change and reason';end if;
 -- Lock product first so size edits and stock changes share one ordering.
 perform 1 from public.gac_merch_products where id=p_product and p_size=any(sizes)for update;if not found then raise exception 'Save this product and option before editing inventory';end if;
 select * into strict s from public.gac_merch_stock where product_id=p_product and size=p_size for update;
 select * into e from gac_private.merch_stock_events where request_id=p_request;
 if found then
  if e.product_id<>p_product or e.size<>p_size or e.actor<>auth.uid()or e.action<>p_action or e.units<>p_units or e.note<>trim(p_note)then raise exception 'Stock request already used';end if;
  return jsonb_build_object('quantity',s.quantity,'revision',s.revision,'replayed',true);
 end if;
 if p_revision is distinct from s.revision then raise exception 'Inventory changed. Refresh stock and try again';end if;
 if p_action<>'count'and s.quantity is null then raise exception 'Set an initial physical count first';end if;
 if p_action in('receive','sale')and p_units<=0 then raise exception 'Enter a positive number of units';end if;
 if p_units not between -1000000 and 1000000 then raise exception 'Stock change is too large';end if;
 n:=case p_action when 'count'then p_units when 'receive'then s.quantity+p_units when 'sale'then s.quantity-p_units else s.quantity+p_units end;
 if n not between 0 and 1000000 then raise exception 'Not enough stock, or count is out of range';end if;
 before_quantity:=s.quantity;
 update public.gac_merch_stock set quantity=n,revision=revision+1,updated_at=clock_timestamp()where product_id=p_product and size=p_size returning * into s;
 insert into gac_private.merch_stock_events(request_id,product_id,size,actor,action,units,previous_quantity,new_quantity,note)values(p_request,p_product,p_size,auth.uid(),p_action,p_units,before_quantity,n,trim(p_note));
 return jsonb_build_object('quantity',s.quantity,'revision',s.revision,'replayed',false);
end $$;
revoke all on function public.gac_owner_change_merch_stock(uuid,text,text,integer,bigint,text,uuid)from public,anon,authenticated;
grant execute on function public.gac_owner_change_merch_stock(uuid,text,text,integer,bigint,text,uuid)to authenticated;
create function public.gac_owner_merch_stock_history(p_product uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$
begin
 if auth.uid()is null or not public.gac_is_owner()then raise exception 'Owner access required'using errcode='42501';end if;
 return(select coalesce(jsonb_agg(x),'[]'::jsonb)from(select size,action,units,previous_quantity,new_quantity,note,created_at from gac_private.merch_stock_events where product_id=p_product order by created_at desc limit 20)x);
end $$;
revoke all on function public.gac_owner_merch_stock_history(uuid)from public,anon,authenticated;
grant execute on function public.gac_owner_merch_stock_history(uuid)to authenticated;
commit;
