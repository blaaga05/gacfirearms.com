begin;

create table gac_private.owner_number_reservations (
 collection_id uuid not null references public.gac_collections(id) on delete cascade,
 edition_number integer not null check(edition_number>0),
 reservation_id uuid not null default extensions.gen_random_uuid(),
 reserved_by uuid not null references auth.users(id),
 reason text check(reason is null or length(reason)<=200),
 created_at timestamptz not null default clock_timestamp(),
 primary key(collection_id,edition_number),
 unique(reservation_id)
);
alter table gac_private.owner_number_reservations enable row level security;
revoke all on gac_private.owner_number_reservations from public,anon,authenticated;

create or replace function public.gac_number_availability(p_collection uuid)
returns table(edition_number integer,number_state text,is_mine boolean,expires_at timestamptz,server_time timestamptz)
language plpgsql security definer set search_path='' as $$
declare c public.gac_collections;t timestamptz:=clock_timestamp();
begin
 if auth.uid()is null or not(public.gac_is_member()or public.gac_is_owner())then raise exception 'Membership required'using errcode='42501';end if;
 select * into strict c from public.gac_collections where id=p_collection;
 if c.archived_at is not null or(c.state='draft'or c.is_test)and not public.gac_is_owner()then raise exception 'Collection unavailable'using errcode='42501';end if;
 return query select x.n,
  case when n.edition_number is not null then 'paid'
       when ownr.edition_number is not null then 'reserved'
       when pay.checkout_id is not null then 'protected'
       when gac_private.payment_check_pending(c.id,x.n)then 'checking'
       when h.edition_number is not null then 'held'
       else 'available' end,
  coalesce(h.user_id=auth.uid(),false),h.expires_at,t
 from generate_series(1,c.quantity)x(n)
 left join public.gac_numbers n on n.collection_id=c.id and n.edition_number=x.n
 left join gac_private.owner_number_reservations ownr on ownr.collection_id=c.id and ownr.edition_number=x.n
 left join gac_private.payment_reservations pay on pay.collection_id=c.id and pay.edition_number=x.n
 left join gac_private.number_holds h on h.collection_id=c.id and h.edition_number=x.n and h.expires_at>t and c.state='open'and c.release_at<=t and(c.recognition_at is null or c.recognition_at>t)
 order by x.n;
end $$;

create or replace function public.gac_hold_number(p_collection uuid,p_number integer)
returns uuid language plpgsql security definer set search_path='' as $$
declare c public.gac_collections;t timestamptz;deadline timestamptz;token uuid;
begin
 if auth.uid() is null or not(public.gac_is_member()or public.gac_is_owner())then raise exception 'Active verified membership required'using errcode='42501';end if;
 select * into strict c from public.gac_collections where id=p_collection for update;
 t:=clock_timestamp();
 if c.is_test and not public.gac_is_owner()then raise exception 'Owner-only test collection'using errcode='42501';end if;
 if c.archived_at is not null or c.state<>'open'or c.release_at>t or(c.recognition_at is not null and c.recognition_at<=t)then raise exception 'Collection is not open';end if;
 if c.selection_paused then raise exception 'Number selection is temporarily paused';end if;
 if p_number is null or p_number<1 or p_number>c.quantity then raise exception 'Invalid number';end if;
 delete from gac_private.number_holds where collection_id=c.id and expires_at<=t;
 if exists(select 1 from public.gac_numbers where collection_id=c.id and edition_number=p_number)then raise exception 'This number is already purchased. Choose another number.';end if;
 if exists(select 1 from gac_private.owner_number_reservations where collection_id=c.id and edition_number=p_number)then raise exception 'This number is reserved by the owner. Choose another number.';end if;
 select hold_id into token from gac_private.number_holds where collection_id=c.id and edition_number=p_number and user_id=auth.uid();
 if found then return token;end if;
 if exists(select 1 from gac_private.number_holds where collection_id=c.id and edition_number=p_number)then raise exception 'Another member just reserved this number. Choose another number.';end if;
 select coalesce(min(expires_at),t+make_interval(mins=>c.hold_minutes)) into deadline from gac_private.number_holds where collection_id=c.id and user_id=auth.uid();
 deadline:=least(deadline,coalesce(c.recognition_at,deadline));
 insert into gac_private.number_holds(collection_id,edition_number,user_id,expires_at)values(c.id,p_number,auth.uid(),deadline)returning hold_id into token;
 return token;
end $$;

create function public.gac_owner_reserve_number(p_collection uuid,p_number integer,p_reason text default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare c public.gac_collections;existing uuid;rid uuid;t timestamptz:=clock_timestamp();
begin
 if auth.uid()is null or not public.gac_is_owner()then raise exception 'Owner access required'using errcode='42501';end if;
 if p_reason is not null and length(trim(p_reason))>200 then raise exception 'Note must be 200 characters or fewer';end if;
 select * into strict c from public.gac_collections where id=p_collection for update;
 if c.archived_at is not null or c.state not in('draft','open')or(c.recognition_at is not null and c.recognition_at<=t)or exists(select 1 from public.gac_recognitions where collection_id=c.id)or exists(select 1 from gac_private.recognition_entries where collection_id=c.id)then raise exception 'Choose a draft or open collection before recognition starts';end if;
 if p_number is null or p_number<1 or p_number>c.quantity then raise exception 'Invalid number';end if;
 delete from gac_private.number_holds where collection_id=c.id and expires_at<=t;
 if exists(select 1 from public.gac_numbers where collection_id=c.id and edition_number=p_number)then raise exception 'This number is already assigned';end if;
 select reservation_id into existing from gac_private.owner_number_reservations where collection_id=c.id and edition_number=p_number;
 if found then return existing;end if;
 if exists(select 1 from gac_private.number_holds where collection_id=c.id and edition_number=p_number and expires_at>t)then raise exception 'This number is currently held by a member';end if;
 if exists(select 1 from gac_private.payment_reservations where collection_id=c.id and edition_number=p_number)or gac_private.payment_check_pending(c.id,p_number)then raise exception 'This number is being used by a checkout or payment review';end if;
 insert into gac_private.owner_number_reservations(collection_id,edition_number,reserved_by,reason)values(c.id,p_number,auth.uid(),nullif(trim(p_reason),''))returning reservation_id into rid;
 return rid;
end $$;

create function public.gac_owner_release_number_reservation(p_collection uuid,p_number integer,p_reservation_id uuid)
returns boolean language plpgsql security definer set search_path='' as $$
declare removed integer;
begin
 if auth.uid()is null or not public.gac_is_owner()then raise exception 'Owner access required'using errcode='42501';end if;
 perform 1 from public.gac_collections where id=p_collection for update;
 delete from gac_private.owner_number_reservations where collection_id=p_collection and edition_number=p_number and reservation_id=p_reservation_id
  and not exists(select 1 from public.gac_numbers where collection_id=p_collection and edition_number=p_number);
 get diagnostics removed=row_count;
 return removed=1;
end $$;

create or replace function public.gac_owner_assign_number(p_collection uuid,p_member uuid,p_number integer,p_kind text,p_reason text,p_reference text,p_request uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare c public.gac_collections;p public.gac_profiles;prior uuid;oid uuid;
begin
 if auth.uid()is null or not public.gac_is_owner()then raise exception 'Owner access required'using errcode='42501';end if;
 if p_request is null or p_kind is null or p_kind not in('complimentary','external_payment')or p_reason is null or length(trim(p_reason))not between 1 and 1000 then raise exception 'Choose an assignment type and enter a reason';end if;
 if p_kind='external_payment'and(p_reference is null or length(trim(p_reference))not between 1 and 200)then raise exception 'Enter the external payment reference';end if;
 select * into strict c from public.gac_collections where id=p_collection for update;
 select a.order_id into prior from gac_private.manual_assignments a join public.gac_orders o on o.id=a.order_id join public.gac_numbers n on n.order_id=o.id where a.request_id=p_request and o.collection_id=p_collection and o.user_id=p_member and o.assignment_kind=p_kind and n.edition_number=p_number and a.reason=trim(p_reason)and coalesce(a.payment_reference,'')=coalesce(nullif(trim(p_reference),''),'');
 if found then return prior;end if;
 if exists(select 1 from gac_private.manual_assignments where request_id=p_request)then raise exception 'Assignment request was already used';end if;
 if c.archived_at is not null or c.state not in('draft','open')or c.recognition_at<=clock_timestamp()or exists(select 1 from public.gac_recognitions where collection_id=c.id)or exists(select 1 from gac_private.recognition_entries where collection_id=c.id)then raise exception 'Choose a draft or open collection before recognition starts';end if;
 select * into strict p from public.gac_profiles where user_id=p_member;
 if p.status<>'active'or not exists(select 1 from auth.users where id=p_member and email_confirmed_at is not null)then raise exception 'Choose an active email-verified member';end if;
 if c.is_test and not exists(select 1 from gac_private.owners where user_id=p_member)then raise exception 'Test groups can only assign to owner accounts';end if;
 if p_number is null or p_number<1 or p_number>c.quantity then raise exception 'Invalid number';end if;
 if exists(select 1 from public.gac_numbers where collection_id=c.id and edition_number=p_number)then raise exception 'This number is already assigned';end if;
 if exists(select 1 from gac_private.number_holds where collection_id=c.id and edition_number=p_number and user_id<>p_member and expires_at>clock_timestamp())then raise exception 'This number is held by another member';end if;
 if exists(select 1 from gac_private.payment_reservations where collection_id=c.id and edition_number=p_number)or gac_private.payment_check_pending(c.id,p_number)then raise exception 'This number is being used by a checkout or payment review';end if;
 insert into public.gac_orders(user_id,collection_id,payment_reference,amount_cents,currency,paid_at,assignment_kind)
 values(p_member,c.id,'OWNER-ASSIGNMENT-'||p_request,case when p_kind='complimentary'then 0 else c.price_cents end,c.currency,clock_timestamp(),p_kind)returning id into oid;
 insert into public.gac_numbers(collection_id,edition_number,order_id,user_id,callsign_at_purchase)values(c.id,p_number,oid,p_member,p.callsign);
 insert into gac_private.manual_assignments(request_id,order_id,assigned_by,reason,payment_reference)values(p_request,oid,auth.uid(),trim(p_reason),nullif(trim(p_reference),''));
 delete from gac_private.number_holds where collection_id=c.id and edition_number=p_number;
 delete from gac_private.owner_number_reservations where collection_id=c.id and edition_number=p_number;
 return oid;
end $$;

create or replace function public.gac_owner_number_holds()
returns table(collection_id uuid,group_callsign text,edition_number integer,user_id uuid,callsign text,full_name text,contact_email text,number_state text,expires_at timestamptz,hold_id uuid,is_test boolean,paid_at timestamptz,server_time timestamptz)
language plpgsql security definer set search_path='' as $$
declare t timestamptz:=clock_timestamp();
begin
 if auth.uid()is null or not public.gac_is_owner()then raise exception 'Owner access required'using errcode='42501';end if;
 return query
 select c.id,c.callsign,h.edition_number,p.user_id,p.callsign,p.full_name,p.contact_email,'held'::text,h.expires_at,h.hold_id,c.is_test,null::timestamptz,t
 from gac_private.number_holds h join public.gac_collections c on c.id=h.collection_id join public.gac_profiles p on p.user_id=h.user_id
 where c.archived_at is null and c.state='open' and h.expires_at>t and(c.recognition_at is null or c.recognition_at>t)
 union all
 select c.id,c.callsign,n.edition_number,p.user_id,n.callsign_at_purchase,p.full_name,p.contact_email,coalesce(o.assignment_kind,'paid'),null::timestamptz,null::uuid,o.is_test,o.paid_at,t
 from public.gac_numbers n join public.gac_collections c on c.id=n.collection_id join public.gac_profiles p on p.user_id=n.user_id join public.gac_orders o on o.id=n.order_id
 where c.archived_at is null and c.state in('open','closed')
 union all
 select c.id,c.callsign,r.edition_number,r.reserved_by,'OWNER RESERVED'::text,r.reason,null::text,'reserved'::text,null::timestamptz,r.reservation_id,c.is_test,r.created_at,t
 from gac_private.owner_number_reservations r join public.gac_collections c on c.id=r.collection_id
 where c.archived_at is null and c.state in('draft','open');
end $$;

revoke all on function public.gac_owner_reserve_number(uuid,integer,text),public.gac_owner_release_number_reservation(uuid,integer,uuid) from public,anon;
grant execute on function public.gac_owner_reserve_number(uuid,integer,text),public.gac_owner_release_number_reservation(uuid,integer,uuid) to authenticated;

commit;
