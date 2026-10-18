begin;
create table gac_private.refund_number_releases(
 checkout_id uuid not null references gac_private.authorizenet_checkouts(id),
 edition_number integer not null,
 refund_cents integer not null check(refund_cents>0),
 actor uuid,
 created_at timestamptz not null default clock_timestamp(),
 primary key(checkout_id,edition_number)
);
alter table gac_private.refund_number_releases enable row level security;
revoke all on gac_private.refund_number_releases from public,anon,authenticated;
create function gac_private.refund_credit(p_checkout uuid)returns bigint language sql stable security definer set search_path=''as $$
 select coalesce(sum(amount_cents),0)from gac_private.gateway_transactions where checkout_id=p_checkout and kind='refundTransaction'and status in('refundPendingSettlement','refundSettledSuccessfully');
$$;
revoke all on function gac_private.refund_credit(uuid)from public,anon,authenticated;
create or replace function gac_private.release_reversed_order_numbers()returns trigger language plpgsql security definer set search_path=''as $$
declare c public.gac_collections;i gac_private.authorizenet_checkouts;removed integer;unit integer;
begin
 select * into i from gac_private.authorizenet_checkouts where order_id=new.id;
 if new.numbers_released_at is not null or new.payment_status not in('voided','refunded','refund_pending')then return new;end if;
 if new.payment_status='refund_pending'and(not found or gac_private.refund_credit(i.id)<new.amount_cents)then return new;end if;
 if exists(select 1 from gac_private.payment_allocations where checkout_id=i.id and manual_release_required)then return new;end if;
 select * into strict c from public.gac_collections where id=new.collection_id for update;
 if c.state<>'open'or c.archived_at is not null or c.recognition_at<=clock_timestamp()or exists(select 1 from gac_private.recognition_entries where collection_id=c.id)or exists(select 1 from public.gac_recognitions where collection_id=c.id)then return new;end if;
 if i.id is not null and new.payment_status in('refunded','refund_pending')then
  unit:=i.amount_cents/cardinality(i.numbers);
  insert into gac_private.refund_number_releases(checkout_id,edition_number,refund_cents)select i.id,n.edition_number,unit from public.gac_numbers n where n.order_id=new.id on conflict do nothing;
 end if;
 delete from public.gac_numbers where order_id=new.id and collection_id=c.id;get diagnostics removed=row_count;
 if removed>0 then new.numbers_released_at:=clock_timestamp();end if;return new;
end $$;
create function public.gac_owner_refund_release(p_transaction text,p_numbers integer[])returns jsonb language plpgsql security definer set search_path=''as $$
declare i gac_private.authorizenet_checkouts;a gac_private.payment_allocations;c public.gac_collections;nums integer[];unit integer;credit bigint;used bigint;n integer;oid uuid;remain integer[];target integer;
begin
 if auth.uid()is null or not public.gac_is_owner()then raise exception 'Owner access required'using errcode='42501';end if;
 select i0.* into strict i from gac_private.authorizenet_checkouts i0 left join gac_private.payment_allocations a0 on a0.checkout_id=i0.id where i0.transaction_id=p_transaction or a0.transaction_id=p_transaction;
 select * into strict c from public.gac_collections where id=i.collection_id for update;
 select * into strict i from gac_private.authorizenet_checkouts where id=i.id for update;
 select * into a from gac_private.payment_allocations where checkout_id=i.id for update;
 if p_numbers is null or cardinality(p_numbers)<1 or cardinality(p_numbers)>cardinality(i.numbers)or exists(select 1 from unnest(p_numbers)x where x is null)or cardinality(p_numbers)<>(select count(distinct x)from unnest(p_numbers)x)then raise exception 'Choose the numbers covered by this refund';end if;
 select array_agg(x order by x)into nums from unnest(p_numbers)x where not exists(select 1 from gac_private.refund_number_releases r where r.checkout_id=i.id and r.edition_number=x);
 if nums is null then return jsonb_build_object('released',0);end if;
 if c.state<>'open'or c.archived_at is not null or c.recognition_at<=clock_timestamp()or exists(select 1 from gac_private.recognition_entries where collection_id=c.id)or exists(select 1 from public.gac_recognitions where collection_id=c.id)then raise exception 'Closed or recognized collection history must remain unchanged';end if;
 if i.amount_cents%cardinality(i.numbers)<>0 then raise exception 'Payment needs manual review: per-number price is not exact';end if;
 unit:=i.amount_cents/cardinality(i.numbers);credit:=gac_private.refund_credit(i.id);
 select coalesce(sum(refund_cents),0)into used from gac_private.refund_number_releases where checkout_id=i.id;
 if cardinality(nums)*unit>credit-used then raise exception 'Sync the refund first. Verified pending or settled refund credit is insufficient';end if;
 if i.order_id is not null then
  if exists(select 1 from unnest(nums)x where not exists(select 1 from public.gac_numbers n where n.order_id=i.order_id and n.edition_number=x))then raise exception 'A selected number no longer belongs to this purchase';end if;
  delete from public.gac_numbers where order_id=i.order_id and edition_number=any(nums);get diagnostics n=row_count;
 else
  if a.checkout_id is null or exists(select 1 from unnest(nums)x where x<>all(i.numbers))then raise exception 'Number is not part of this pending purchase';end if;
  if not exists(select 1 from gac_private.gateway_transactions where checkout_id=i.id and transaction_id=a.transaction_id and kind='authCaptureTransaction'and status in('capturedPendingSettlement','settledSuccessfully')and amount_cents=i.amount_cents)then raise exception 'Verified captured payment required';end if;
  delete from gac_private.payment_reservations where checkout_id=i.id and edition_number=any(nums);
  n:=cardinality(nums);
 end if;
 insert into gac_private.refund_number_releases(checkout_id,edition_number,refund_cents,actor)select i.id,x,unit,auth.uid()from unnest(nums)x;
 if i.order_id is null then
  select coalesce(array_agg(edition_number order by edition_number),'{}'::integer[])into remain from gac_private.payment_reservations where checkout_id=i.id;
  target:=cardinality(i.numbers)-(select count(*)from gac_private.refund_number_releases where checkout_id=i.id);
  update gac_private.payment_allocations set selected_numbers=remain,updated_at=clock_timestamp()where checkout_id=i.id;
  if target=0 then
   update gac_private.payment_allocations set state='released',released_at=clock_timestamp()where checkout_id=i.id;
  elsif cardinality(remain)=target then
   -- A partial refund covers the missing original number; retain protected originals without another payment.
   insert into public.gac_orders(user_id,collection_id,payment_reference,amount_cents,currency,paid_at,acknowledgment,acknowledged_at)values(i.user_id,i.collection_id,'AUTHNET-'||a.transaction_id,i.amount_cents,i.currency,a.submitted_at,i.acknowledgment,i.created_at)returning id into oid;
   update gac_private.authorizenet_checkouts set order_id=oid,status='credited',transaction_id=a.transaction_id,token=null,review_reason=null where id=i.id;
   insert into public.gac_numbers(collection_id,edition_number,order_id,user_id,callsign_at_purchase)select i.collection_id,x,oid,i.user_id,i.callsign from unnest(remain)x;
   delete from gac_private.payment_reservations where checkout_id=i.id;
   update gac_private.payment_allocations set state='fulfilled',last_status='capturedPendingSettlement'where checkout_id=i.id;
   update public.gac_orders set payment_status=case when exists(select 1 from gac_private.gateway_transactions where checkout_id=i.id and kind='refundTransaction'and status='refundPendingSettlement')then 'refund_pending'else 'partially_refunded'end where id=oid;
  else
   update gac_private.payment_allocations set state='manual_review'where checkout_id=i.id;
  end if;
 else
  if not exists(select 1 from public.gac_numbers where order_id=i.order_id)then
   update public.gac_orders set numbers_released_at=clock_timestamp()where id=i.order_id;
   update gac_private.payment_allocations set state='released',released_at=clock_timestamp()where checkout_id=i.id;
  end if;
 end if;
 update gac_private.authorizenet_payment_reviews set resolved_at=clock_timestamp(),resolution='Owner applied verified pending/settled refund to selected numbers'where checkout_id=i.id and transaction_id=p_transaction;
 insert into gac_private.payment_allocation_events(checkout_id,kind,numbers,actor)values(i.id,'refund_numbers_released',nums,auth.uid());
 return jsonb_build_object('released',n,'remaining_refund_credit_cents',credit-used-cardinality(nums)*unit);
end $$;
revoke all on function public.gac_owner_refund_release(text,integer[])from public,anon,authenticated;
grant execute on function public.gac_owner_refund_release(text,integer[])to authenticated;
create function public.gac_owner_refund_release_details()returns jsonb language plpgsql stable security definer set search_path=''as $$
begin
 if auth.uid()is null or not public.gac_is_owner()then raise exception 'Owner access required'using errcode='42501';end if;
 return(select coalesce(jsonb_agg(x),'[]'::jsonb)from(select coalesce(i.transaction_id,a.transaction_id)as transaction_id,i.user_id as member_id,p.callsign,p.full_name,p.contact_email,c.callsign as collection,i.amount_cents,i.currency,i.order_id is null as pending_allocation,coalesce((select array_agg(n.edition_number order by n.edition_number)from public.gac_numbers n where n.order_id=i.order_id),case when i.order_id is null then i.numbers else '{}'::integer[]end)as numbers,i.amount_cents/cardinality(i.numbers)as unit_cents,gac_private.refund_credit(i.id)as refund_credit_cents,(select coalesce(sum(refund_cents),0)from gac_private.refund_number_releases where checkout_id=i.id)as released_credit_cents,coalesce(a.manual_release_required,false)as manual_release_required,c.state='open'and c.archived_at is null and(c.recognition_at is null or c.recognition_at>clock_timestamp())and not exists(select 1 from public.gac_recognitions where collection_id=c.id)and not exists(select 1 from gac_private.recognition_entries where collection_id=c.id)as can_release,(select coalesce(array_agg(edition_number),'{}'::integer[])from gac_private.refund_number_releases where checkout_id=i.id)as released_numbers from gac_private.authorizenet_checkouts i join public.gac_profiles p on p.user_id=i.user_id join public.gac_collections c on c.id=i.collection_id left join gac_private.payment_allocations a on a.checkout_id=i.id where exists(select 1 from gac_private.gateway_transactions where checkout_id=i.id and kind='refundTransaction'and status in('refundPendingSettlement','refundSettledSuccessfully'))order by i.created_at desc limit 100)x);
end $$;
revoke all on function public.gac_owner_refund_release_details()from public,anon,authenticated;
grant execute on function public.gac_owner_refund_release_details()to authenticated;
create function gac_private.alert_failed_released_refund()returns trigger language plpgsql security definer set search_path=''as $$
declare i gac_private.authorizenet_checkouts;reason text;
begin
 if new.kind<>'refundTransaction'or new.status in('refundPendingSettlement','refundSettledSuccessfully')or not exists(select 1 from gac_private.refund_number_releases where checkout_id=new.checkout_id)then return new;end if;
 if tg_op='UPDATE'and new.status is not distinct from old.status then return new;end if;
 select * into strict i from gac_private.authorizenet_checkouts where id=new.checkout_id;
 reason:='Refund changed to '||new.status||' after number release. Review the refund in Authorize.net. Numbers must not be reclaimed from a later purchaser.';
 insert into gac_private.authorizenet_payment_reviews(transaction_id,checkout_id,reason)values(new.transaction_id,i.id,reason)on conflict(transaction_id)do update set reason=excluded.reason,resolved_at=null,resolution=null;
 update public.gac_messages set body='REFUND NEEDS GAC REVIEW · Reference '||new.transaction_id||'. '||reason||' Contact GAC before paying again.',owner_read_at=null where payment_review_transaction=new.transaction_id;
 return new;
end $$;
revoke all on function gac_private.alert_failed_released_refund()from public,anon,authenticated;
create trigger refund_release_failure_alert after insert or update on gac_private.gateway_transactions for each row execute function gac_private.alert_failed_released_refund();

create or replace function public.gac_apply_authorizenet_payment(p_transaction text,p_invoice text,p_amount_cents integer,p_paid_at timestamptz,p_status text,p_currency text default 'usd') returns text language plpgsql security definer set search_path='' as $$
declare i gac_private.authorizenet_checkouts;c public.gac_collections;a gac_private.payment_allocations;reason text;s text:=replace(p_status,'unapproved:','');chosen integer[];existing uuid;held boolean:=s in('FDSPendingReview','FDSAuthorizedPendingReview');approved boolean:=p_status in('capturedPendingSettlement','settledSuccessfully');
begin
 if (select auth.role()) is distinct from 'service_role' then raise exception 'Service access required';end if;
 if p_transaction!~'^[0-9]{1,30}$' then raise exception 'Invalid transaction';end if;
 select * into i from gac_private.authorizenet_checkouts where invoice=p_invoice;if not found then return 'unrelated';end if;
 select * into strict c from public.gac_collections where id=i.collection_id for update;
 select * into strict i from gac_private.authorizenet_checkouts where id=i.id for update;
 select * into a from gac_private.payment_allocations where checkout_id=i.id for update;
 if i.order_id is null and exists(select 1 from gac_private.gateway_transactions where checkout_id=i.id and kind='refundTransaction'and status in('refundPendingSettlement','refundSettledSuccessfully'))then
  if(select coalesce(sum(amount_cents),0)from gac_private.gateway_transactions where checkout_id=i.id and kind='refundTransaction'and status='refundSettledSuccessfully')>=i.amount_cents then s:='refundSettledSuccessfully';else reason:='A pending or partial refund requires owner review';end if;
 end if;
 if reason is not null then null;
 elsif a.checkout_id is not null and a.transaction_id<>p_transaction then reason:='Another payment is already associated with this checkout';
 elsif s in('voided','declined','expired','failedReview','refundSettledSuccessfully') then
  update gac_private.payment_allocations set state=case when state='released' then state else 'voided' end,last_status=s,updated_at=clock_timestamp() where checkout_id=i.id;
  update gac_private.authorizenet_checkouts set payment_checked_at=clock_timestamp() where id=i.id;return 'voided';
 else
  select id into existing from public.gac_orders where payment_reference='AUTHNET-'||p_transaction;
  if existing is not null then if i.order_id=existing then return 'credited';else raise exception 'Transaction already used';end if;end if;
  if i.order_id is not null then reason:='Another payment was already credited';
  elsif a.state='released' then reason:='This payment allocation was manually released';
  elsif not approved and not held then return 'ignored';
  elsif p_amount_cents is distinct from i.amount_cents or lower(p_currency) is distinct from i.currency then reason:='Payment amount or currency mismatch';
  elsif p_paid_at is null or p_paid_at<i.created_at-interval '1 minute' or p_paid_at>clock_timestamp()+interval '1 minute' then reason:='Payment timestamp mismatch';
  elsif c.is_test or c.archived_at is not null or c.state<>'open' or c.release_at>clock_timestamp() or c.recognition_at<=clock_timestamp() or exists(select 1 from public.gac_recognitions where collection_id=c.id) or exists(select 1 from gac_private.recognition_entries where collection_id=c.id) then reason:='Collection closed or recognition already started';
  elsif not exists(select 1 from public.gac_profiles where user_id=i.user_id and status='active') then reason:='Membership is no longer active';end if;
 end if;
 if reason is not null then
  insert into gac_private.authorizenet_payment_reviews(transaction_id,checkout_id,reason)values(p_transaction,i.id,reason)on conflict(transaction_id)do update set reason=excluded.reason;
  if i.order_id is null then update gac_private.authorizenet_checkouts set status='review',review_reason=reason,token=null where id=i.id;end if;
  if a.checkout_id is not null and a.state<>'released' then update gac_private.payment_allocations set state='manual_review',last_status=s,updated_at=clock_timestamp() where checkout_id=i.id;end if;
  return 'review';
 end if;
 insert into gac_private.payment_allocations(checkout_id,transaction_id,state,submitted_at,last_status,manual_release_required) values(i.id,p_transaction,case when held then 'protected' else 'choosing' end,p_paid_at,s,held and p_paid_at<=i.expires_at) on conflict(checkout_id)do update set last_status=excluded.last_status,manual_release_required=gac_private.payment_allocations.manual_release_required or excluded.manual_release_required,updated_at=clock_timestamp();
 if not held or p_paid_at<=i.expires_at then
  select coalesce(array_agg(x order by x),'{}'::integer[]) into chosen from unnest(i.numbers)x where gac_private.payment_number_free(c.id,x,i.id);
  insert into gac_private.payment_reservations(collection_id,edition_number,checkout_id)select c.id,x,i.id from unnest(chosen)x on conflict(collection_id,edition_number)do nothing;
 end if;
 select coalesce(array_agg(edition_number order by edition_number),'{}'::integer[]) into chosen from gac_private.payment_reservations where checkout_id=i.id;
 update gac_private.payment_allocations set selected_numbers=chosen,state=case when held then 'protected' else 'choosing' end where checkout_id=i.id;
 delete from gac_private.number_holds where collection_id=c.id and hold_id=any(i.hold_ids) and edition_number=any(chosen);
 update gac_private.authorizenet_checkouts set payment_checked_at=clock_timestamp(),token=null where id=i.id;
 if held then return 'protected';end if;
 if cardinality(chosen)=cardinality(i.numbers) then return gac_private.finish_payment_allocation(i.id);end if;
 update gac_private.authorizenet_checkouts set status='review',review_reason='Your hold expired and one or more numbers are no longer available. Choose replacements without paying again.' where id=i.id;
 insert into gac_private.authorizenet_payment_reviews(transaction_id,checkout_id,reason) values(p_transaction,i.id,'Hold expired; payment verified. Available original numbers are protected while replacements are chosen.') on conflict(transaction_id)do update set reason=excluded.reason;
 return 'replacement';
end $$;

create or replace function gac_private.guard_unfulfilled_payment_refund()returns trigger language plpgsql security definer set search_path=''as $$
declare total bigint;pending bigint;due integer;
begin
 if new.kind<>'refundTransaction'then return new;end if;
 select amount_cents into due from gac_private.authorizenet_checkouts where id=new.checkout_id;
 select coalesce(sum(amount_cents)filter(where status='refundSettledSuccessfully'),0),coalesce(sum(amount_cents)filter(where status='refundPendingSettlement'),0)into total,pending from gac_private.gateway_transactions where checkout_id=new.checkout_id and kind='refundTransaction';
 if total>=due then update gac_private.payment_allocations set state='voided',last_status='refundSettledSuccessfully',updated_at=clock_timestamp()where checkout_id=new.checkout_id and released_at is null;
 elsif (total>0 or pending>0)and exists(select 1 from gac_private.authorizenet_checkouts where id=new.checkout_id and order_id is null)then update gac_private.payment_allocations set state='manual_review',last_status=case when pending>0 then 'refundPendingSettlement'else 'partially_refunded'end,updated_at=clock_timestamp()where checkout_id=new.checkout_id and released_at is null;end if;return new;
end $$;

-- Apply verified full pending refunds already present; partial purchases remain assigned until owner choice.
update public.gac_orders set payment_status=payment_status where payment_status in('refund_pending','refunded')and numbers_released_at is null;
commit;
