begin;

create or replace function gac_private.collection_payment_readiness(p_collection uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
 c public.gac_collections;
 assigned integer;
 eligible integer;
 finished integer;
 remaining_spins integer;
 uncaptured integer;
 open_reviews integer;
 open_allocations integer;
 order_rows jsonb;
 blockers text[] := '{}'::text[];
begin
 select * into strict c from public.gac_collections where id=p_collection;
 select count(*)::integer into assigned from public.gac_numbers where collection_id=p_collection;
 select count(*)::integer into finished from public.gac_recognitions where collection_id=p_collection;
 select count(*)::integer into eligible from public.gac_numbers n
  where n.collection_id=p_collection and not exists(
   select 1 from public.gac_recognitions r where r.collection_id=n.collection_id and r.edition_number=n.edition_number);
 remaining_spins:=greatest(c.spin_count-coalesce(finished,0),0);

 select count(*)::integer into uncaptured
 from public.gac_orders o
 where o.collection_id=p_collection and o.amount_cents>0
 and (
  o.payment_status is distinct from 'paid'
  or o.payment_reference not like 'AUTHNET-%'
  or not exists(
   select 1 from gac_private.authorizenet_checkouts i
   join gac_private.gateway_transactions g on g.checkout_id=i.id
   where i.order_id=o.id
    and i.transaction_id=substring(o.payment_reference from 9)
    and g.transaction_id=i.transaction_id
    and g.kind='authCaptureTransaction'
    and g.status in ('capturedPendingSettlement','settledSuccessfully')
    and g.amount_cents=o.amount_cents
  )
 );

 select count(*)::integer into open_reviews
 from gac_private.authorizenet_payment_reviews r
 join gac_private.authorizenet_checkouts i on i.id=r.checkout_id
 where i.collection_id=p_collection and r.resolved_at is null;

 select count(distinct a.checkout_id)::integer into open_allocations
 from gac_private.payment_allocations a
 join gac_private.authorizenet_checkouts i on i.id=a.checkout_id
 where i.collection_id=p_collection and a.released_at is null
 and (a.state in ('protected','choosing','manual_review')
      or a.manual_release_required);

 select coalesce(jsonb_agg(x order by x->>'member',x->>'numbers'),'[]'::jsonb)
 into order_rows
 from (
  select jsonb_build_object(
   'member',coalesce(p.callsign,'Member'),
   'numbers',coalesce((select array_agg(n.edition_number order by n.edition_number)
                       from public.gac_numbers n where n.order_id=o.id),'{}'::integer[]),
   'amount_cents',o.amount_cents,
   'payment_reference',o.payment_reference,
   'payment_status',o.payment_status,
   'assignment_kind',o.assignment_kind,
   'transaction_id',case when o.payment_reference like 'AUTHNET-%' then substring(o.payment_reference from 9) end,
   'gateway_status',g.status,
   'verified',case
     when o.amount_cents=0 and o.assignment_kind='complimentary' then true
     else o.amount_cents>0 and o.payment_status='paid'
      and o.payment_reference like 'AUTHNET-%'
      and g.status in ('capturedPendingSettlement','settledSuccessfully')
      and g.amount_cents=o.amount_cents
   end
  ) as x
  from public.gac_orders o
  left join public.gac_profiles p on p.user_id=o.user_id
  left join lateral (
   select gt.status,gt.amount_cents
   from gac_private.authorizenet_checkouts i
   join gac_private.gateway_transactions gt on gt.checkout_id=i.id
   where i.order_id=o.id
    and i.transaction_id=case when o.payment_reference like 'AUTHNET-%' then substring(o.payment_reference from 9) end
    and gt.transaction_id=i.transaction_id
    and gt.kind='authCaptureTransaction'
   order by gt.observed_at desc
   limit 1
  ) g on true
  where o.collection_id=p_collection
 ) q;

 if c.archived_at is not null then blockers:=array_append(blockers,'Collection is archived.'); end if;
 if c.is_test then blockers:=array_append(blockers,'Test collections cannot be marked ready.'); end if;
 if c.state not in ('open','closed') then blockers:=array_append(blockers,'Open or close the collection before drawing.'); end if;
 if assigned<c.quantity then blockers:=array_append(blockers,'Not all numbers are assigned ('||assigned||' of '||c.quantity||').'); end if;
 if eligible<remaining_spins then blockers:=array_append(blockers,'There are not enough eligible numbers for the remaining spins.'); end if;
 if uncaptured>0 then blockers:=array_append(blockers,uncaptured||' paid order(s) do not have a matching captured Authorize.Net transaction.'); end if;
 if open_reviews>0 then blockers:=array_append(blockers,open_reviews||' payment review(s) are unresolved.'); end if;
 if open_allocations>0 then blockers:=array_append(blockers,open_allocations||' protected or incomplete payment allocation(s) remain.'); end if;
 if remaining_spins=0 then blockers:=array_append(blockers,'All configured spins are already complete.'); end if;

 return jsonb_build_object(
  'ready',cardinality(blockers)=0,
  'collection_id',c.id,
  'callsign',c.callsign,
  'state',c.state,
  'quantity',c.quantity,
  'assigned',assigned,
  'eligible_numbers',eligible,
  'spins_total',c.spin_count,
  'spins_complete',finished,
  'spins_remaining',remaining_spins,
  'paid_orders', (select count(*) from public.gac_orders o where o.collection_id=p_collection and o.amount_cents>0),
  'uncaptured_orders',uncaptured,
  'open_reviews',open_reviews,
  'open_allocations',open_allocations,
  'blockers',to_jsonb(blockers),
  'orders',coalesce(order_rows,'[]'::jsonb)
 );
end
$function$;

revoke all on function gac_private.collection_payment_readiness(uuid) from public,anon,authenticated;

create or replace function public.gac_owner_collection_payment_readiness(p_collection uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
 if auth.uid() is null or not public.gac_is_owner() then
  raise exception 'Owner access required' using errcode='42501';
 end if;
 return gac_private.collection_payment_readiness(p_collection);
end
$function$;
revoke all on function public.gac_owner_collection_payment_readiness(uuid) from public,anon;
grant execute on function public.gac_owner_collection_payment_readiness(uuid) to authenticated;

create or replace function public.gac_owner_payment_allocations()
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
 if auth.uid() is null or not public.gac_is_owner() then
  raise exception 'Owner access required' using errcode='42501';
 end if;
 return (
  select coalesce(jsonb_agg(x),'[]'::jsonb)
  from (
   select a.checkout_id,a.transaction_id,a.state,a.last_status,a.manual_release_required,
    a.selected_numbers,i.user_id as member_id,p.callsign,p.full_name,p.contact_email,
    c.callsign as collection,i.amount_cents,i.currency,a.updated_at
   from gac_private.payment_allocations a
   join gac_private.authorizenet_checkouts i on i.id=a.checkout_id
   join public.gac_profiles p on p.user_id=i.user_id
   join public.gac_collections c on c.id=i.collection_id
   where a.released_at is null
    and (a.state<>'voided' or a.manual_release_required
      or exists(select 1 from gac_private.payment_reservations r where r.checkout_id=a.checkout_id))
    and (a.state in ('protected','choosing','voided','manual_review')
      or a.manual_release_required and a.last_status in ('voided','refundSettledSuccessfully'))
   order by a.updated_at desc limit 100
  ) x
 );
end
$function$;

create or replace function public.gac_draw_due_collection(p_collection uuid)
returns public.gac_recognitions
language plpgsql
security definer
set search_path to ''
as $function$
declare
 c public.gac_collections;
 result public.gac_recognitions;
 readiness jsonb;
 n integer;
 sample bigint;
 ceiling bigint;
 bytes bytea;
 chosen gac_private.recognition_entries;
 round_number integer;
begin
 select * into strict c from public.gac_collections where id=p_collection for update;
 select * into result from public.gac_recognitions where collection_id=p_collection order by spin_number desc limit 1;
 if found then
  if c.state='recognized' or result.spin_number>=c.spin_count
   or now()<result.selected_at+make_interval(secs=>(c.wheel_settings->>'duration')::integer+c.spin_pause_seconds) then
   return result;
  end if;
 elsif c.state not in ('open','closed') or c.recognition_at is null or c.recognition_at>now() then
  raise exception 'Collection is not due';
 end if;

 readiness:=gac_private.collection_payment_readiness(p_collection);
 if not coalesce((readiness->>'ready')::boolean,false) then
  raise exception 'Collection is not ready to spin: %',
   array_to_string(array(select jsonb_array_elements_text(readiness->'blockers')),' ');
 end if;

 if result.collection_id is null then
  insert into gac_private.recognition_entries(collection_id,edition_number,member_id,callsign_snapshot)
  select ent.collection_id,ent.edition_number,ent.user_id,p.callsign
  from public.gac_numbers ent join public.gac_profiles p on p.user_id=ent.user_id
  where ent.collection_id=p_collection on conflict do nothing;
 end if;
 select count(*) into n from gac_private.recognition_entries e
 where e.collection_id=p_collection and not exists(
  select 1 from public.gac_recognitions r where r.collection_id=e.collection_id and r.edition_number=e.edition_number);
 if n=0 then raise exception 'No eligible purchased numbers';end if;
 round_number:=coalesce(result.spin_number,0)+1;
 ceiling:=4294967296-(4294967296 % n);
 loop
  bytes:=extensions.gen_random_bytes(4);
  sample:=get_byte(bytes,0)::bigint*16777216+get_byte(bytes,1)::bigint*65536+get_byte(bytes,2)::bigint*256+get_byte(bytes,3)::bigint;
  exit when sample<ceiling;
 end loop;
 select * into strict chosen from gac_private.recognition_entries e
 where e.collection_id=p_collection and not exists(
  select 1 from public.gac_recognitions r where r.collection_id=e.collection_id and r.edition_number=e.edition_number)
 order by e.edition_number offset(sample%n) limit 1;
 insert into public.gac_recognitions(collection_id,spin_number,edition_number,member_id,selected_callsign,eligible_number_count)
 values(p_collection,round_number,chosen.edition_number,chosen.member_id,chosen.callsign_snapshot,n)
 returning * into result;
 update public.gac_collections set state=case when round_number>=c.spin_count or n=1 then 'recognized' else 'closed' end where id=p_collection;
 return result;
end
$function$;

commit;