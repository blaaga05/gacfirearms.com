begin;
alter table public.gac_collections add column selection_paused boolean not null default false;
create function public.gac_owner_set_selection_paused(p_collection uuid,p_paused boolean) returns boolean language plpgsql security definer set search_path='' as $$
declare c public.gac_collections;
begin
 if auth.uid() is null or not public.gac_is_owner() then raise exception 'Owner access required' using errcode='42501';end if;
 if p_paused is null then raise exception 'Choose pause or resume';end if;
 select * into strict c from public.gac_collections where id=p_collection for update;
 if c.archived_at is not null or c.state not in ('draft','open') or c.recognition_at<=clock_timestamp() or exists(select 1 from gac_private.recognition_entries where collection_id=c.id) or exists(select 1 from public.gac_recognitions where collection_id=c.id) then raise exception 'Choose a draft or open collection before recognition starts';end if;
 update public.gac_collections set selection_paused=p_paused where id=c.id;
 return p_paused;
end $$;
revoke all on function public.gac_owner_set_selection_paused(uuid,boolean) from public,anon;
grant execute on function public.gac_owner_set_selection_paused(uuid,boolean) to authenticated;
create or replace function public.gac_hold_number(p_collection uuid,p_number integer)
returns uuid language plpgsql security definer set search_path='' as $$
declare c public.gac_collections; t timestamptz; deadline timestamptz; token uuid;
begin
 if auth.uid() is null or not (public.gac_is_member() or public.gac_is_owner()) then raise exception 'Active verified membership required' using errcode='42501';end if;
 select * into strict c from public.gac_collections where id=p_collection for update;
 t:=clock_timestamp();
 if c.is_test and not public.gac_is_owner() then raise exception 'Owner-only test collection' using errcode='42501';end if;
 if c.archived_at is not null or c.state<>'open' or c.release_at>t or (c.recognition_at is not null and c.recognition_at<=t) then raise exception 'Collection is not open';end if;
 if c.selection_paused then raise exception 'Number selection is temporarily paused';end if;
 if p_number is null or p_number<1 or p_number>c.quantity then raise exception 'Invalid number';end if;
 delete from gac_private.number_holds where collection_id=c.id and expires_at<=t;
 if exists(select 1 from public.gac_numbers where collection_id=c.id and edition_number=p_number) then raise exception 'This number is already purchased. Choose another number.';end if;
 select hold_id into token from gac_private.number_holds where collection_id=c.id and edition_number=p_number and user_id=auth.uid();
 if found then return token;end if;
 if exists(select 1 from gac_private.number_holds where collection_id=c.id and edition_number=p_number) then raise exception 'Another member just reserved this number. Choose another number.';end if;
 select coalesce(min(expires_at),t+make_interval(mins=>c.hold_minutes)) into deadline from gac_private.number_holds where collection_id=c.id and user_id=auth.uid();
 deadline:=least(deadline,coalesce(c.recognition_at,deadline));
 insert into gac_private.number_holds(collection_id,edition_number,user_id,expires_at) values(c.id,p_number,auth.uid(),deadline) returning hold_id into token;
 return token;
end $$;

create or replace function public.gac_owner_assign_number(p_collection uuid,p_member uuid,p_number integer,p_kind text,p_reason text,p_reference text,p_request uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare c public.gac_collections;p public.gac_profiles;prior uuid;oid uuid;
begin
 if auth.uid() is null or not public.gac_is_owner() then raise exception 'Owner access required' using errcode='42501';end if;
 if p_request is null or p_kind is null or p_kind not in('complimentary','external_payment') or p_reason is null or length(trim(p_reason)) not between 1 and 1000 then raise exception 'Choose an assignment type and enter a reason';end if;
 if p_kind='external_payment' and (p_reference is null or length(trim(p_reference)) not between 1 and 200) then raise exception 'Enter the external payment reference';end if;
 select * into strict c from public.gac_collections where id=p_collection for update;
 select a.order_id into prior from gac_private.manual_assignments a join public.gac_orders o on o.id=a.order_id join public.gac_numbers n on n.order_id=o.id where a.request_id=p_request and o.collection_id=p_collection and o.user_id=p_member and o.assignment_kind=p_kind and n.edition_number=p_number and a.reason=trim(p_reason) and coalesce(a.payment_reference,'')=coalesce(nullif(trim(p_reference),''),'');
 if found then return prior;end if;
 if exists(select 1 from gac_private.manual_assignments where request_id=p_request) then raise exception 'Assignment request was already used';end if;
 if c.archived_at is not null or c.state not in ('draft','open') or c.recognition_at<=clock_timestamp() or exists(select 1 from public.gac_recognitions where collection_id=c.id) or exists(select 1 from gac_private.recognition_entries where collection_id=c.id) then raise exception 'Choose a draft or open collection before recognition starts';end if;
 select * into strict p from public.gac_profiles where user_id=p_member;
 if p.status<>'active' or not exists(select 1 from auth.users where id=p_member and email_confirmed_at is not null) then raise exception 'Choose an active email-verified member';end if;
 if c.is_test and not exists(select 1 from gac_private.owners where user_id=p_member) then raise exception 'Test groups can only assign to owner accounts';end if;
 if p_number is null or p_number<1 or p_number>c.quantity then raise exception 'Invalid number';end if;
 if exists(select 1 from public.gac_numbers where collection_id=c.id and edition_number=p_number) then raise exception 'This number is already assigned';end if;
 if exists(select 1 from gac_private.number_holds where collection_id=c.id and edition_number=p_number and user_id<>p_member and expires_at>clock_timestamp()) then raise exception 'This number is held by another member';end if;
 insert into public.gac_orders(user_id,collection_id,payment_reference,amount_cents,currency,paid_at,assignment_kind)
 values(p_member,c.id,'OWNER-ASSIGNMENT-'||p_request,case when p_kind='complimentary' then 0 else c.price_cents end,c.currency,clock_timestamp(),p_kind) returning id into oid;
 insert into public.gac_numbers(collection_id,edition_number,order_id,user_id,callsign_at_purchase) values(c.id,p_number,oid,p_member,p.callsign);
 insert into gac_private.manual_assignments(request_id,order_id,assigned_by,reason,payment_reference) values(p_request,oid,auth.uid(),trim(p_reason),nullif(trim(p_reference),''));
 delete from gac_private.number_holds where collection_id=c.id and edition_number=p_number;
 return oid;
end $$;
revoke all on function public.gac_owner_assign_number(uuid,uuid,integer,text,text,text,uuid) from public,anon;
grant execute on function public.gac_owner_assign_number(uuid,uuid,integer,text,text,text,uuid) to authenticated;

commit;
