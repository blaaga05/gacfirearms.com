begin;
alter table public.gac_orders add column assignment_kind text check(assignment_kind in('complimentary','external_payment'));
alter table public.gac_orders drop constraint gac_orders_amount_cents_check;
alter table public.gac_orders add constraint gac_orders_amount_cents_check check((assignment_kind is not distinct from 'complimentary' and amount_cents=0) or (assignment_kind is distinct from 'complimentary' and amount_cents>0));
create table gac_private.manual_assignments(request_id uuid primary key,order_id uuid not null unique references public.gac_orders(id) on delete cascade,assigned_by uuid not null references auth.users(id),reason text not null check(length(trim(reason)) between 1 and 1000),payment_reference text,created_at timestamptz not null default now());
alter table gac_private.manual_assignments enable row level security;
revoke all on gac_private.manual_assignments from public,anon,authenticated;
create function public.gac_owner_assign_number(p_collection uuid,p_member uuid,p_number integer,p_kind text,p_reason text,p_reference text,p_request uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare c public.gac_collections;p public.gac_profiles;prior uuid;oid uuid;
begin
 if auth.uid() is null or not public.gac_is_owner() then raise exception 'Owner access required' using errcode='42501';end if;
 if p_request is null or p_kind is null or p_kind not in('complimentary','external_payment') or p_reason is null or length(trim(p_reason)) not between 1 and 1000 then raise exception 'Choose an assignment type and enter a reason';end if;
 if p_kind='external_payment' and (p_reference is null or length(trim(p_reference)) not between 1 and 200) then raise exception 'Enter the external payment reference';end if;
 select * into strict c from public.gac_collections where id=p_collection for update;
 select a.order_id into prior from gac_private.manual_assignments a join public.gac_orders o on o.id=a.order_id join public.gac_numbers n on n.order_id=o.id where a.request_id=p_request and o.collection_id=p_collection and o.user_id=p_member and o.assignment_kind=p_kind and n.edition_number=p_number and a.reason=trim(p_reason) and coalesce(a.payment_reference,'')=coalesce(nullif(trim(p_reference),''),'');
 if found then return prior;end if;
 if exists(select 1 from gac_private.manual_assignments where request_id=p_request) then raise exception 'Assignment request was already used';end if;
 if c.archived_at is not null or c.state<>'open' or c.release_at>clock_timestamp() or c.recognition_at<=clock_timestamp() or exists(select 1 from public.gac_recognitions where collection_id=c.id) then raise exception 'Choose an open collection before recognition starts';end if;
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

create or replace function public.gac_owner_number_holds()
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
 select c.id,c.callsign,n.edition_number,p.user_id,n.callsign_at_purchase,p.full_name,p.contact_email,coalesce(o.assignment_kind,'paid'),null::timestamptz,null::uuid,o.is_test,o.paid_at,t
 from public.gac_numbers n join public.gac_collections c on c.id=n.collection_id join public.gac_profiles p on p.user_id=n.user_id join public.gac_orders o on o.id=n.order_id
 where c.archived_at is null and c.state in('open','closed');
end $$;

commit;
