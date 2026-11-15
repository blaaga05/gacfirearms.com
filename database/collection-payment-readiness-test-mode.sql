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
  if c.state not in ('open','closed') then blockers:=array_append(blockers,'Open or close the collection before drawing.'); end if;
 if not c.is_test and assigned<c.quantity then blockers:=array_append(blockers,'Not all numbers are assigned ('||assigned||' of '||c.quantity||').'); end if;
 if eligible<remaining_spins then blockers:=array_append(blockers,'There are not enough eligible numbers for the remaining spins.'); end if;
 if not c.is_test and uncaptured>0 then blockers:=array_append(blockers,uncaptured||' paid order(s) do not have a matching captured Authorize.Net transaction.'); end if;
 if not c.is_test and open_reviews>0 then blockers:=array_append(blockers,open_reviews||' payment review(s) are unresolved.'); end if;
 if not c.is_test and open_allocations>0 then blockers:=array_append(blockers,open_allocations||' protected or incomplete payment allocation(s) remain.'); end if;
 if remaining_spins=0 then blockers:=array_append(blockers,'All configured spins are already complete.'); end if;

 return jsonb_build_object(
  'ready',cardinality(blockers)=0,
  'collection_id',c.id,
  'callsign',c.callsign,
  'state',c.state,
  'is_test',c.is_test,
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
commit;