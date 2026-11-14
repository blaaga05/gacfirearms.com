begin;

alter table public.gac_collections
  drop constraint if exists gac_collections_price_cents_check;

alter table public.gac_collections
  add constraint gac_collections_price_cents_check check (price_cents >= 0);

create or replace function public.gac_owner_assign_number(
  p_collection uuid,
  p_member uuid,
  p_number integer,
  p_kind text,
  p_reason text,
  p_reference text,
  p_request uuid
) returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  c public.gac_collections;
  p public.gac_profiles;
  prior uuid;
  oid uuid;
begin
  if auth.uid() is null or not public.gac_is_owner() then
    raise exception 'Owner access required' using errcode='42501';
  end if;
  if p_request is null or p_kind is null or p_kind not in ('complimentary','external_payment')
     or p_reason is null or length(trim(p_reason)) not between 1 and 1000 then
    raise exception 'Choose an assignment type and enter a reason';
  end if;
  if p_kind='external_payment' and (p_reference is null or length(trim(p_reference)) not between 1 and 200) then
    raise exception 'Enter the external payment reference';
  end if;

  select * into strict c from public.gac_collections where id=p_collection for update;
  select a.order_id into prior
  from gac_private.manual_assignments a
  join public.gac_orders o on o.id=a.order_id
  join public.gac_numbers n on n.order_id=o.id
  where a.request_id=p_request and o.collection_id=p_collection and o.user_id=p_member
    and o.assignment_kind=p_kind and n.edition_number=p_number and a.reason=trim(p_reason)
    and coalesce(a.payment_reference,'')=coalesce(nullif(trim(p_reference),''),'');
  if found then return prior; end if;
  if exists(select 1 from gac_private.manual_assignments where request_id=p_request) then
    raise exception 'Assignment request was already used';
  end if;
  if c.archived_at is not null or c.state not in ('draft','open','closed')
     or c.recognition_at<=clock_timestamp()
     or exists(select 1 from public.gac_recognitions where collection_id=c.id)
     or exists(select 1 from gac_private.recognition_entries where collection_id=c.id) then
    raise exception 'Choose a draft, open, or closed collection before recognition starts';
  end if;

  select * into strict p from public.gac_profiles where user_id=p_member;
  if p.status<>'active' or not exists(select 1 from auth.users where id=p_member and email_confirmed_at is not null) then
    raise exception 'Choose an active email-verified member';
  end if;
  if c.is_test and not exists(select 1 from gac_private.owners where user_id=p_member) then
    raise exception 'Test groups can only assign to owner accounts';
  end if;
  if p_number is null or p_number<1 or p_number>c.quantity then raise exception 'Invalid number'; end if;
  if exists(select 1 from public.gac_numbers where collection_id=c.id and edition_number=p_number) then
    raise exception 'This number is already assigned';
  end if;
  if exists(select 1 from gac_private.number_holds where collection_id=c.id and edition_number=p_number
            and user_id<>p_member and expires_at>clock_timestamp()) then
    raise exception 'This number is held by another member';
  end if;
  if exists(select 1 from gac_private.payment_reservations where collection_id=c.id and edition_number=p_number)
     or gac_private.payment_check_pending(c.id,p_number) then
    raise exception 'This number is being used by a checkout or payment review';
  end if;

  insert into public.gac_orders(user_id,collection_id,payment_reference,amount_cents,currency,paid_at,assignment_kind)
  values(p_member,c.id,'OWNER-ASSIGNMENT-'||p_request,
         case when p_kind='complimentary' then 0 else c.price_cents end,c.currency,clock_timestamp(),p_kind)
  returning id into oid;
  insert into public.gac_numbers(collection_id,edition_number,order_id,user_id,callsign_at_purchase)
  values(c.id,p_number,oid,p_member,p.callsign);
  insert into gac_private.manual_assignments(request_id,order_id,assigned_by,reason,payment_reference)
  values(p_request,oid,auth.uid(),trim(p_reason),nullif(trim(p_reference),''));
  delete from gac_private.number_holds where collection_id=c.id and edition_number=p_number;
  delete from gac_private.owner_number_reservations where collection_id=c.id and edition_number=p_number;
  return oid;
end
$function$;

create or replace function public.gac_free_checkout(
  p_collection uuid,
  p_numbers integer[],
  p_acknowledged boolean,
  p_request uuid
) returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  c public.gac_collections;
  p public.gac_profiles;
  r public.gac_requirements;
  existing public.gac_orders;
  oid uuid;
  distinct_count integer;
  payment_ref text;
begin
  if auth.uid() is null or not public.gac_is_member() then
    raise exception 'Active membership required' using errcode='42501';
  end if;
  if p_acknowledged is distinct from true then raise exception 'Acknowledge the collection terms first'; end if;
  if p_request is null or p_numbers is null or cardinality(p_numbers)<1 then
    raise exception 'Select at least one number';
  end if;
  select count(distinct n) into distinct_count from unnest(p_numbers) as selected(n);
  if distinct_count<1 or distinct_count<>cardinality(p_numbers) then
    raise exception 'Select each number only once';
  end if;

  select * into strict c from public.gac_collections where id=p_collection for update;
  payment_ref:='FREE-'||p_request::text;
  select * into existing from public.gac_orders where payment_reference=payment_ref;
  if found then
    if existing.user_id<>auth.uid() or existing.collection_id<>p_collection or existing.amount_cents<>0
       or existing.assignment_kind is distinct from 'complimentary'
       or (select array_agg(n.edition_number order by n.edition_number)
           from public.gac_numbers n where n.order_id=existing.id)
          is distinct from (select array_agg(x order by x) from unnest(p_numbers) x) then
      raise exception 'Free checkout request conflict';
    end if;
    return existing.id;
  end if;

  if c.archived_at is not null or c.is_test or c.price_cents<>0 or c.state<>'open'
     or c.release_at>clock_timestamp()
     or (c.recognition_at is not null and c.recognition_at<=clock_timestamp()) then
    raise exception 'This free collection is not open for selection';
  end if;
  select * into strict p from public.gac_profiles where user_id=auth.uid();
  if p.status<>'active' or not exists(select 1 from auth.users where id=auth.uid() and email_confirmed_at is not null) then
    raise exception 'Active email-verified membership required';
  end if;
  if exists(select 1 from unnest(p_numbers) as selected(n) where n is null or n<1 or n>c.quantity) then
    raise exception 'Invalid number selection';
  end if;
  if exists(
    select 1 from unnest(p_numbers) as selected(n)
    where not exists(select 1 from gac_private.number_holds h
      where h.collection_id=c.id and h.edition_number=n and h.user_id=auth.uid()
        and h.expires_at>clock_timestamp())
  ) then
    raise exception 'Your number hold expired or was released. Select available numbers again.';
  end if;
  if exists(select 1 from unnest(p_numbers) as selected(n)
            join gac_private.owner_number_reservations rsv on rsv.collection_id=c.id and rsv.edition_number=n)
     or exists(select 1 from unnest(p_numbers) as selected(n)
               join gac_private.payment_reservations pr on pr.collection_id=c.id and pr.edition_number=n)
     or exists(select 1 from unnest(p_numbers) as selected(n) where gac_private.payment_check_pending(c.id,n)) then
    raise exception 'A selected number is reserved or under payment review';
  end if;

  select * into strict r from public.gac_requirements where singleton;
  insert into public.gac_orders(user_id,collection_id,payment_reference,amount_cents,currency,paid_at,
                                assignment_kind,acknowledgment,acknowledged_at)
  values(auth.uid(),c.id,payment_ref,0,c.currency,clock_timestamp(),'complimentary',r.recognition_statement,clock_timestamp())
  returning id into oid;
  insert into public.gac_numbers(collection_id,edition_number,order_id,user_id,callsign_at_purchase)
  select c.id,n,oid,auth.uid(),p.callsign from unnest(p_numbers) as selected(n);
  delete from gac_private.number_holds where collection_id=c.id and user_id=auth.uid()
    and edition_number=any(p_numbers);
  return oid;
end
$function$;

revoke all on function public.gac_free_checkout(uuid, integer[], boolean, uuid) from public, anon;
grant execute on function public.gac_free_checkout(uuid, integer[], boolean, uuid) to authenticated;

commit;
