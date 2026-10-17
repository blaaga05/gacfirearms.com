begin;
create or replace function public.gac_apply_authorizenet_payment(p_transaction text,p_invoice text,p_amount_cents integer,p_paid_at timestamptz,p_status text,p_currency text default 'usd') returns text language plpgsql security definer set search_path='' as $$
declare i gac_private.authorizenet_checkouts;c public.gac_collections;a gac_private.payment_allocations;reason text;s text:=replace(p_status,'unapproved:','');chosen integer[];existing uuid;held boolean:=s in('FDSPendingReview','FDSAuthorizedPendingReview');approved boolean:=p_status in('capturedPendingSettlement','settledSuccessfully');
begin
 if (select auth.role()) is distinct from 'service_role' then raise exception 'Service access required';end if;
 if p_transaction!~'^[0-9]{1,30}$' then raise exception 'Invalid transaction';end if;
 select * into i from gac_private.authorizenet_checkouts where invoice=p_invoice;if not found then return 'unrelated';end if;
 select * into strict c from public.gac_collections where id=i.collection_id for update;
 select * into strict i from gac_private.authorizenet_checkouts where id=i.id for update;
 select * into a from gac_private.payment_allocations where checkout_id=i.id for update;
 if exists(select 1 from gac_private.gateway_transactions where checkout_id=i.id and kind='refundTransaction'and status in('refundPendingSettlement','refundSettledSuccessfully'))then
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
create or replace function public.gac_owner_payment_allocations() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid()is null or not public.gac_is_owner()then raise exception 'Owner access required' using errcode='42501';end if;
 return(select coalesce(jsonb_agg(x),'[]'::jsonb)from(select a.transaction_id,a.state,a.last_status,a.manual_release_required,a.selected_numbers,i.user_id as member_id,p.callsign,p.full_name,p.contact_email,c.callsign as collection,i.amount_cents,i.currency,a.updated_at from gac_private.payment_allocations a join gac_private.authorizenet_checkouts i on i.id=a.checkout_id join public.gac_profiles p on p.user_id=i.user_id join public.gac_collections c on c.id=i.collection_id where a.released_at is null and(a.state<>'voided'or a.manual_release_required or exists(select 1 from gac_private.payment_reservations r where r.checkout_id=a.checkout_id))and(a.state in('protected','choosing','voided','manual_review')or a.manual_release_required and a.last_status in('voided','refundSettledSuccessfully'))order by a.updated_at desc limit 100)x);
end $$;
create or replace function public.gac_my_payment_allocations() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not(public.gac_is_member()or public.gac_is_owner())then raise exception 'Membership required' using errcode='42501';end if;
 return(select coalesce(jsonb_agg(x),'[]'::jsonb)from(select a.transaction_id,a.state,a.last_status,a.manual_release_required,i.collection_id,c.callsign as collection,i.numbers as original_numbers,a.selected_numbers,cardinality(i.numbers)-cardinality(a.selected_numbers)as needed,c.state='open'and c.archived_at is null and(c.recognition_at is null or c.recognition_at>clock_timestamp())and not c.selection_paused as can_choose,(select coalesce(jsonb_agg(n),'[]'::jsonb)from generate_series(1,c.quantity)n where n<>all(a.selected_numbers)and gac_private.payment_number_free(c.id,n,i.id))as available_numbers from gac_private.payment_allocations a join gac_private.authorizenet_checkouts i on i.id=a.checkout_id join public.gac_collections c on c.id=i.collection_id where i.user_id=auth.uid()and(a.state<>'voided'or a.manual_release_required or exists(select 1 from gac_private.payment_reservations r where r.checkout_id=a.checkout_id))and a.state in('protected','choosing','voided','manual_review')order by a.updated_at desc)x);
end $$;

create function gac_private.guard_unfulfilled_payment_refund()returns trigger language plpgsql security definer set search_path=''as $$
declare total bigint;pending bigint;due integer;
begin
 if new.kind<>'refundTransaction'then return new;end if;
 select amount_cents into due from gac_private.authorizenet_checkouts where id=new.checkout_id;
 select coalesce(sum(amount_cents)filter(where status='refundSettledSuccessfully'),0),coalesce(sum(amount_cents)filter(where status='refundPendingSettlement'),0)into total,pending from gac_private.gateway_transactions where checkout_id=new.checkout_id and kind='refundTransaction';
 if total>=due then update gac_private.payment_allocations set state='voided',last_status='refundSettledSuccessfully',updated_at=clock_timestamp()where checkout_id=new.checkout_id and released_at is null;
 elsif total>0 or pending>0 then update gac_private.payment_allocations set state='manual_review',last_status=case when pending>0 then 'refundPendingSettlement'else 'partially_refunded'end,updated_at=clock_timestamp()where checkout_id=new.checkout_id and released_at is null;end if;return new;
end $$;
revoke all on function gac_private.guard_unfulfilled_payment_refund()from public,anon,authenticated;
create trigger unfulfilled_payment_refund_guard after insert or update on gac_private.gateway_transactions for each row execute function gac_private.guard_unfulfilled_payment_refund();

commit;
