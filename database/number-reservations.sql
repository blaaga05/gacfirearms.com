begin;
create table gac_private.number_holds (
 collection_id uuid not null references public.gac_collections(id) on delete cascade,
 edition_number integer not null check(edition_number>0),
 user_id uuid not null references public.gac_profiles(user_id) on delete cascade,
 hold_id uuid not null default extensions.gen_random_uuid(),
 created_at timestamptz not null default clock_timestamp(),
 expires_at timestamptz not null,
 primary key(collection_id,edition_number)
);
create index number_holds_member_idx on gac_private.number_holds(user_id,collection_id);
alter table gac_private.number_holds enable row level security;
revoke all on gac_private.number_holds from public,anon,authenticated;

create function gac_private.clear_closed_number_holds() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.state<>'open' or new.archived_at is not null or new.release_at>clock_timestamp() or new.is_test is distinct from old.is_test then
  delete from gac_private.number_holds where collection_id=new.id;
 elsif new.recognition_at is not null then
  update gac_private.number_holds set expires_at=least(expires_at,new.recognition_at) where collection_id=new.id;
 end if;
 return new;
end $$;
revoke all on function gac_private.clear_closed_number_holds() from public,anon,authenticated;
create trigger gac_clear_closed_number_holds after update of state,archived_at,release_at,recognition_at,is_test on public.gac_collections for each row execute function gac_private.clear_closed_number_holds();

create function public.gac_number_availability(p_collection uuid)
returns table(edition_number integer,number_state text,is_mine boolean,expires_at timestamptz,server_time timestamptz)
language plpgsql security definer set search_path='' as $$
declare c public.gac_collections; t timestamptz:=clock_timestamp();
begin
 if auth.uid() is null or not (public.gac_is_member() or public.gac_is_owner()) then raise exception 'Membership required' using errcode='42501';end if;
 select * into strict c from public.gac_collections where id=p_collection;
 if c.archived_at is not null or (c.state='draft' or c.is_test) and not public.gac_is_owner() then raise exception 'Collection unavailable' using errcode='42501';end if;
 return query select x.n,case when n.edition_number is not null then 'paid' when h.edition_number is not null then 'held' else 'available' end,
 coalesce(h.user_id=auth.uid(),false),h.expires_at,t
 from generate_series(1,c.quantity) x(n)
 left join public.gac_numbers n on n.collection_id=c.id and n.edition_number=x.n
 left join gac_private.number_holds h on h.collection_id=c.id and h.edition_number=x.n and h.expires_at>t
 and c.state='open' and c.release_at<=t and (c.recognition_at is null or c.recognition_at>t)
 order by x.n;
end $$;

create function public.gac_hold_number(p_collection uuid,p_number integer)
returns uuid language plpgsql security definer set search_path='' as $$
declare c public.gac_collections; t timestamptz; deadline timestamptz; token uuid;
begin
 if auth.uid() is null or not (public.gac_is_member() or public.gac_is_owner()) then raise exception 'Active verified membership required' using errcode='42501';end if;
 select * into strict c from public.gac_collections where id=p_collection for update;
 t:=clock_timestamp();
 if c.is_test and not public.gac_is_owner() then raise exception 'Owner-only test collection' using errcode='42501';end if;
 if c.archived_at is not null or c.state<>'open' or c.release_at>t or (c.recognition_at is not null and c.recognition_at<=t) then raise exception 'Collection is not open';end if;
 if p_number is null or p_number<1 or p_number>c.quantity then raise exception 'Invalid number';end if;
 delete from gac_private.number_holds where collection_id=c.id and expires_at<=t;
 if exists(select 1 from public.gac_numbers where collection_id=c.id and edition_number=p_number) then raise exception 'This number is already purchased. Choose another number.';end if;
 select hold_id into token from gac_private.number_holds where collection_id=c.id and edition_number=p_number and user_id=auth.uid();
 if found then return token;end if;
 if exists(select 1 from gac_private.number_holds where collection_id=c.id and edition_number=p_number) then raise exception 'Another member just reserved this number. Choose another number.';end if;
 select coalesce(min(expires_at),t+interval '10 minutes') into deadline from gac_private.number_holds where collection_id=c.id and user_id=auth.uid();
 deadline:=least(deadline,coalesce(c.recognition_at,deadline));
 insert into gac_private.number_holds(collection_id,edition_number,user_id,expires_at) values(c.id,p_number,auth.uid(),deadline) returning hold_id into token;
 return token;
end $$;

create function public.gac_release_my_numbers(p_collection uuid,p_number integer default null)
returns integer language plpgsql security definer set search_path='' as $$
declare removed integer;
begin
 if auth.uid() is null then raise exception 'Sign in required' using errcode='42501';end if;
 perform 1 from public.gac_collections where id=p_collection for update;
 delete from gac_private.number_holds where collection_id=p_collection and user_id=auth.uid() and (p_number is null or edition_number=p_number);
 get diagnostics removed=row_count;return removed;
end $$;

create function public.gac_owner_number_holds()
returns table(collection_id uuid,group_callsign text,edition_number integer,user_id uuid,callsign text,full_name text,contact_email text,number_state text,expires_at timestamptz,hold_id uuid,is_test boolean,paid_at timestamptz,server_time timestamptz)
language plpgsql security definer set search_path='' as $$
declare t timestamptz:=clock_timestamp();
begin
 if auth.uid() is null or not public.gac_is_owner() then raise exception 'Owner access required' using errcode='42501';end if;
 return query
 select c.id,c.callsign,h.edition_number,p.user_id,p.callsign,p.full_name,p.contact_email,'held'::text,h.expires_at,h.hold_id,c.is_test,null::timestamptz,t
 from gac_private.number_holds h join public.gac_collections c on c.id=h.collection_id join public.gac_profiles p on p.user_id=h.user_id
 where c.archived_at is null and c.state='open' and h.expires_at>t and (c.recognition_at is null or c.recognition_at>t)
 union all
 select c.id,c.callsign,n.edition_number,p.user_id,n.callsign_at_purchase,p.full_name,p.contact_email,'paid'::text,null::timestamptz,null::uuid,o.is_test,o.paid_at,t
 from public.gac_numbers n join public.gac_collections c on c.id=n.collection_id join public.gac_profiles p on p.user_id=n.user_id join public.gac_orders o on o.id=n.order_id
 where c.archived_at is null and c.state in('open','closed');
end $$;

create function public.gac_owner_release_hold(p_collection uuid,p_number integer,p_hold_id uuid)
returns boolean language plpgsql security definer set search_path='' as $$
declare removed integer;
begin
 if auth.uid() is null or not public.gac_is_owner() then raise exception 'Owner access required' using errcode='42501';end if;
 perform 1 from public.gac_collections where id=p_collection for update;
 delete from gac_private.number_holds where collection_id=p_collection and edition_number=p_number and hold_id=p_hold_id
 and not exists(select 1 from public.gac_numbers where collection_id=p_collection and edition_number=p_number);
 get diagnostics removed=row_count;return removed=1;
end $$;

revoke all on function public.gac_number_availability(uuid),public.gac_hold_number(uuid,integer),public.gac_release_my_numbers(uuid,integer),public.gac_owner_number_holds(),public.gac_owner_release_hold(uuid,integer,uuid) from public,anon;
grant execute on function public.gac_number_availability(uuid),public.gac_hold_number(uuid,integer),public.gac_release_my_numbers(uuid,integer),public.gac_owner_number_holds(),public.gac_owner_release_hold(uuid,integer,uuid) to authenticated;

create or replace function public.gac_record_verified_purchase(p_member uuid,p_collection uuid,p_numbers integer[],p_payment_reference text,p_amount_cents integer,p_paid_at timestamptz)
returns uuid language plpgsql security definer set search_path = '' as $$
declare c public.gac_collections; p public.gac_profiles; existing public.gac_orders; order_id uuid; distinct_count integer;
begin
 if length(trim(p_payment_reference))=0 then raise exception 'Payment reference required'; end if;
 select * into existing from public.gac_orders where payment_reference=p_payment_reference;
 if found then
  if existing.user_id<>p_member or existing.collection_id<>p_collection or existing.amount_cents<>p_amount_cents
   or (select array_agg(n.edition_number order by n.edition_number) from public.gac_numbers n where n.order_id=existing.id)
      is distinct from (select array_agg(x order by x) from unnest(p_numbers) x) then raise exception 'Idempotency conflict'; end if;
  return existing.id;
 end if;
 select * into strict c from public.gac_collections where id=p_collection for update;
 if c.is_test and not public.gac_is_owner() then raise exception 'Test checkout requires owner access';end if;
 select * into strict p from public.gac_profiles where user_id=p_member;
 if p.status<>'active' or not exists(select 1 from auth.users where id=p_member and email_confirmed_at is not null)
  then raise exception 'Active verified membership required'; end if;
 if c.state<>'open' or c.release_at>now() or (c.recognition_at is not null and c.recognition_at<=now()) then raise exception 'Collection is not open'; end if;
 select count(distinct x) into distinct_count from unnest(p_numbers) x;
 if distinct_count<1 or distinct_count<>cardinality(p_numbers)
  or exists(select 1 from unnest(p_numbers) x where x is null or x<1 or x>c.quantity)
  or p_amount_cents<>c.price_cents*distinct_count then raise exception 'Invalid numbers or payment amount'; end if;
 if exists(select 1 from unnest(p_numbers) x where not exists(select 1 from gac_private.number_holds h where h.collection_id=c.id and h.edition_number=x and h.user_id=p_member and h.expires_at>clock_timestamp())) then raise exception 'Your number hold expired or was released. Select available numbers again before checkout.';end if;
 insert into public.gac_orders(user_id,collection_id,payment_reference,amount_cents,currency,paid_at)
 values(p_member,p_collection,p_payment_reference,p_amount_cents,c.currency,p_paid_at) returning id into order_id;
 insert into public.gac_numbers(collection_id,edition_number,order_id,user_id,callsign_at_purchase)
 select p_collection,x,order_id,p_member,p.callsign from unnest(p_numbers) x;
 delete from gac_private.number_holds where collection_id=c.id and user_id=p_member and edition_number=any(p_numbers);
 return order_id;
end $$;

commit;
