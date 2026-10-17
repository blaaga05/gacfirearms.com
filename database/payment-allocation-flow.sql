begin;
alter table gac_private.authorizenet_checkouts add column payment_checked_at timestamptz;
create table gac_private.payment_allocations(checkout_id uuid primary key references gac_private.authorizenet_checkouts(id),transaction_id text not null unique,state text not null check(state in('protected','choosing','fulfilled','voided','manual_review','released')),selected_numbers integer[] not null default '{}',submitted_at timestamptz not null,last_status text not null,manual_release_required boolean not null default false,released_at timestamptz,updated_at timestamptz not null default clock_timestamp());
create table gac_private.payment_reservations(collection_id uuid not null references public.gac_collections(id),edition_number integer not null,checkout_id uuid not null references gac_private.payment_allocations(checkout_id),primary key(collection_id,edition_number));
create index payment_reservations_checkout_idx on gac_private.payment_reservations(checkout_id);
create table gac_private.payment_allocation_events(id bigint generated always as identity primary key,checkout_id uuid not null references gac_private.authorizenet_checkouts(id),kind text not null,numbers integer[],actor uuid,created_at timestamptz not null default clock_timestamp());
alter table gac_private.payment_allocations enable row level security;
alter table gac_private.payment_reservations enable row level security;
alter table gac_private.payment_allocation_events enable row level security;
revoke all on gac_private.payment_allocations,gac_private.payment_reservations,gac_private.payment_allocation_events from public,anon,authenticated;
create function gac_private.payment_check_pending(p_collection uuid,p_number integer,p_except uuid default null) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from gac_private.authorizenet_checkouts i where i.collection_id=p_collection and p_number=any(i.numbers) and i.id is distinct from p_except and i.token_claimed_at is not null and i.order_id is null and i.expires_at<=clock_timestamp() and coalesce(i.payment_checked_at,'-infinity'::timestamptz)<i.expires_at and not exists(select 1 from gac_private.payment_allocations a where a.checkout_id=i.id));
$$;
create function gac_private.payment_number_free(p_collection uuid,p_number integer,p_checkout uuid) returns boolean language sql stable security definer set search_path='' as $$
 select p_number between 1 and(select quantity from public.gac_collections where id=p_collection)and not exists(select 1 from public.gac_numbers where collection_id=p_collection and edition_number=p_number)
 and not exists(select 1 from gac_private.payment_reservations where collection_id=p_collection and edition_number=p_number and checkout_id<>p_checkout)
 and not exists(select 1 from gac_private.number_holds h where h.collection_id=p_collection and h.edition_number=p_number and h.expires_at>clock_timestamp() and not exists(select 1 from gac_private.authorizenet_checkouts i where i.id=p_checkout and h.hold_id=any(i.hold_ids)))
 and not gac_private.payment_check_pending(p_collection,p_number,p_checkout);
$$;
create function gac_private.guard_payment_reserved_number() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if TG_TABLE_NAME='number_holds' then
  if exists(select 1 from gac_private.payment_reservations where collection_id=new.collection_id and edition_number=new.edition_number) then raise exception 'This number is protected for a payment';end if;
  if gac_private.payment_check_pending(new.collection_id,new.edition_number) then raise exception 'Checking an earlier payment. Please try again shortly.';end if;
 else
  if exists(select 1 from gac_private.payment_reservations r join gac_private.authorizenet_checkouts i on i.id=r.checkout_id where r.collection_id=new.collection_id and r.edition_number=new.edition_number and i.order_id is distinct from new.order_id) then raise exception 'This number is protected for a payment';end if;
  if gac_private.payment_check_pending(new.collection_id,new.edition_number) then raise exception 'Checking an earlier payment. Please try again shortly.';end if;
 end if;return new;
end $$;
create trigger protect_payment_number_hold before insert on gac_private.number_holds for each row execute function gac_private.guard_payment_reserved_number();
create trigger protect_payment_number_assignment before insert on public.gac_numbers for each row execute function gac_private.guard_payment_reserved_number();
create function gac_private.finish_payment_allocation(p_checkout uuid) returns text language plpgsql security definer set search_path='' as $$
declare i gac_private.authorizenet_checkouts;a gac_private.payment_allocations;oid uuid;
begin
 select * into strict i from gac_private.authorizenet_checkouts where id=p_checkout for update;select * into strict a from gac_private.payment_allocations where checkout_id=p_checkout for update;
 if i.order_id is not null then return 'credited';end if;
 if a.last_status not in('capturedPendingSettlement','settledSuccessfully') or cardinality(a.selected_numbers)<>cardinality(i.numbers) then raise exception 'Verified complete payment allocation required';end if;
 if (select count(*) from gac_private.payment_reservations where checkout_id=i.id)<>cardinality(i.numbers) then raise exception 'Payment reservations changed';end if;
 insert into public.gac_orders(user_id,collection_id,payment_reference,amount_cents,currency,paid_at,acknowledgment,acknowledged_at) values(i.user_id,i.collection_id,'AUTHNET-'||a.transaction_id,i.amount_cents,i.currency,a.submitted_at,i.acknowledgment,i.created_at) returning id into oid;
 update gac_private.authorizenet_checkouts set status='credited',transaction_id=a.transaction_id,order_id=oid,token=null,review_reason=null where id=i.id;
 insert into public.gac_numbers(collection_id,edition_number,order_id,user_id,callsign_at_purchase) select i.collection_id,x,oid,i.user_id,i.callsign from unnest(a.selected_numbers)x;
 delete from gac_private.number_holds where collection_id=i.collection_id and hold_id=any(i.hold_ids);
 delete from gac_private.payment_reservations where checkout_id=i.id;
 update gac_private.payment_allocations set state='fulfilled',updated_at=clock_timestamp() where checkout_id=i.id;
 update gac_private.authorizenet_payment_reviews set resolved_at=clock_timestamp(),resolution='Verified payment allocated' where transaction_id=a.transaction_id;
 insert into gac_private.payment_allocation_events(checkout_id,kind,numbers) values(i.id,'fulfilled',a.selected_numbers);
 return 'credited';
end $$;
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
create function public.gac_choose_paid_replacements(p_member uuid,p_transaction text,p_numbers integer[]) returns text language plpgsql security definer set search_path='' as $$
declare i gac_private.authorizenet_checkouts;a gac_private.payment_allocations;c public.gac_collections;nums integer[];
begin
 if (select auth.role()) is distinct from 'service_role' then raise exception 'Service access required';end if;
 select i0.* into strict i from gac_private.authorizenet_checkouts i0 join gac_private.payment_allocations a0 on a0.checkout_id=i0.id where a0.transaction_id=p_transaction and i0.user_id=p_member;
 select * into strict c from public.gac_collections where id=i.collection_id for update;select * into strict a from gac_private.payment_allocations where checkout_id=i.id for update;
 if a.state='fulfilled' then return 'credited';end if;
 if a.state<>'choosing' or a.last_status not in('capturedPendingSettlement','settledSuccessfully') then raise exception 'Payment is not available for replacement selection';end if;
 if c.selection_paused then raise exception 'Number selection is temporarily paused';end if;
 if c.state<>'open' or c.archived_at is not null or c.release_at>clock_timestamp() or c.recognition_at<=clock_timestamp() or exists(select 1 from gac_private.recognition_entries where collection_id=c.id) or exists(select 1 from public.gac_recognitions where collection_id=c.id) then raise exception 'Collection closed. Contact GAC to resolve this payment.';end if;
 if not exists(select 1 from public.gac_profiles where user_id=p_member and status='active') then raise exception 'Active membership required';end if;
 select array_agg(x order by x)into nums from unnest(p_numbers)x;
 if cardinality(nums) is distinct from cardinality(i.numbers)-cardinality(a.selected_numbers) or cardinality(nums)<>(select count(distinct x)from unnest(nums)x) or exists(select 1 from unnest(nums)x where x is null or x<1 or x>c.quantity or x=any(a.selected_numbers) or not gac_private.payment_number_free(c.id,x,i.id)) then raise exception 'One of those numbers is no longer available. Refresh and choose again.';end if;
 insert into gac_private.payment_reservations(collection_id,edition_number,checkout_id)select c.id,x,i.id from unnest(nums)x;
 update gac_private.payment_allocations set selected_numbers=(select array_agg(x order by x)from unnest(a.selected_numbers||nums)x) where checkout_id=i.id;
 insert into gac_private.payment_allocation_events(checkout_id,kind,numbers,actor)values(i.id,'replacements_chosen',nums,p_member);
 return gac_private.finish_payment_allocation(i.id);
end $$;
create function public.gac_my_payment_allocations() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not(public.gac_is_member()or public.gac_is_owner())then raise exception 'Membership required' using errcode='42501';end if;
 return(select coalesce(jsonb_agg(x),'[]'::jsonb)from(select a.transaction_id,a.state,a.last_status,a.manual_release_required,i.collection_id,c.callsign as collection,i.numbers as original_numbers,a.selected_numbers,cardinality(i.numbers)-cardinality(a.selected_numbers)as needed,c.state='open'and c.archived_at is null and(c.recognition_at is null or c.recognition_at>clock_timestamp())and not c.selection_paused as can_choose,(select coalesce(jsonb_agg(n),'[]'::jsonb)from generate_series(1,c.quantity)n where n<>all(a.selected_numbers)and gac_private.payment_number_free(c.id,n,i.id))as available_numbers from gac_private.payment_allocations a join gac_private.authorizenet_checkouts i on i.id=a.checkout_id join public.gac_collections c on c.id=i.collection_id where i.user_id=auth.uid()and a.state in('protected','choosing','voided','manual_review')order by a.updated_at desc)x);
end $$;
create function public.gac_owner_payment_allocations() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid()is null or not public.gac_is_owner()then raise exception 'Owner access required' using errcode='42501';end if;
 return(select coalesce(jsonb_agg(x),'[]'::jsonb)from(select a.transaction_id,a.state,a.last_status,a.manual_release_required,a.selected_numbers,i.user_id as member_id,p.callsign,p.full_name,p.contact_email,c.callsign as collection,i.amount_cents,i.currency,a.updated_at from gac_private.payment_allocations a join gac_private.authorizenet_checkouts i on i.id=a.checkout_id join public.gac_profiles p on p.user_id=i.user_id join public.gac_collections c on c.id=i.collection_id where a.released_at is null and(a.state in('protected','choosing','voided','manual_review')or a.manual_release_required and a.last_status in('voided','refundSettledSuccessfully'))order by a.updated_at desc limit 100)x);
end $$;
create function public.gac_owner_release_payment_numbers(p_transaction text)returns integer language plpgsql security definer set search_path='' as $$
declare i gac_private.authorizenet_checkouts;a gac_private.payment_allocations;c public.gac_collections;n integer:=0;k integer;
begin
 if auth.uid()is null or not public.gac_is_owner()then raise exception 'Owner access required' using errcode='42501';end if;
 select i0.* into strict i from gac_private.authorizenet_checkouts i0 join gac_private.payment_allocations a0 on a0.checkout_id=i0.id where a0.transaction_id=p_transaction;
 select * into strict c from public.gac_collections where id=i.collection_id for update;select * into strict a from gac_private.payment_allocations where checkout_id=i.id for update;
 if a.released_at is not null then return 0;end if;
 if a.last_status not in('voided','declined','expired','failedReview','refundSettledSuccessfully')then raise exception 'Void or refund the payment in Authorize.net first, then sync payments before releasing.';end if;
 if i.order_id is not null then
  if c.state<>'open' or c.archived_at is not null or exists(select 1 from public.gac_recognitions where collection_id=c.id)or exists(select 1 from gac_private.recognition_entries where collection_id=c.id)then raise exception 'Closed or recognized collection history must remain unchanged';end if;
  delete from public.gac_numbers where order_id=i.order_id;get diagnostics n=row_count;
  update public.gac_orders set numbers_released_at=clock_timestamp()where id=i.order_id;
 end if;
 delete from gac_private.payment_reservations where checkout_id=i.id;get diagnostics k=row_count;n:=n+k;
 update gac_private.payment_allocations set state='released',released_at=clock_timestamp(),updated_at=clock_timestamp()where checkout_id=i.id;
 update gac_private.authorizenet_payment_reviews set resolved_at=clock_timestamp(),resolution='Verified reversal; owner manually released numbers'where transaction_id=p_transaction;
 insert into gac_private.payment_allocation_events(checkout_id,kind,numbers,actor)values(i.id,'owner_released',a.selected_numbers,auth.uid());return n;
end $$;
create or replace function public.gac_number_availability(p_collection uuid)returns table(edition_number integer,number_state text,is_mine boolean,expires_at timestamptz,server_time timestamptz)language plpgsql security definer set search_path=''as $$
declare c public.gac_collections;t timestamptz:=clock_timestamp();
begin
 if auth.uid()is null or not(public.gac_is_member()or public.gac_is_owner())then raise exception 'Membership required'using errcode='42501';end if;
 select * into strict c from public.gac_collections where id=p_collection;
 if c.archived_at is not null or(c.state='draft'or c.is_test)and not public.gac_is_owner()then raise exception 'Collection unavailable'using errcode='42501';end if;
 return query select x.n,case when n.edition_number is not null then 'paid'when r.checkout_id is not null then 'protected'when gac_private.payment_check_pending(c.id,x.n)then 'checking'when h.edition_number is not null then 'held'else 'available'end,coalesce(h.user_id=auth.uid(),false),h.expires_at,t from generate_series(1,c.quantity)x(n)left join public.gac_numbers n on n.collection_id=c.id and n.edition_number=x.n left join gac_private.payment_reservations r on r.collection_id=c.id and r.edition_number=x.n left join gac_private.number_holds h on h.collection_id=c.id and h.edition_number=x.n and h.expires_at>t and c.state='open'and c.release_at<=t and(c.recognition_at is null or c.recognition_at>t)order by x.n;
end $$;
create function public.gac_expired_unchecked_checkouts()returns jsonb language plpgsql security definer set search_path=''as $$
begin
 if(select auth.role())is distinct from 'service_role'then raise exception 'Service access required';end if;
 return(select coalesce(jsonb_agg(x),'[]'::jsonb)from(select i.id,i.invoice,i.expires_at from gac_private.authorizenet_checkouts i where i.token_claimed_at is not null and i.order_id is null and i.expires_at<=clock_timestamp()and coalesce(i.payment_checked_at,'-infinity'::timestamptz)<i.expires_at and not exists(select 1 from gac_private.payment_allocations a where a.checkout_id=i.id)order by i.expires_at limit 20)x);
end $$;
create function public.gac_mark_payment_expiry_checked(p_checkouts uuid[],p_checked_at timestamptz)returns void language plpgsql security definer set search_path=''as $$
begin
 if(select auth.role())is distinct from 'service_role'then raise exception 'Service access required';end if;
 if p_checked_at>clock_timestamp()or p_checked_at<clock_timestamp()-interval '2 minutes'then raise exception 'Invalid payment check time';end if;
 update gac_private.authorizenet_checkouts set payment_checked_at=p_checked_at where id=any(p_checkouts)and expires_at<=p_checked_at;
end $$;
-- All privileged allocation helpers are private; public entrypoints below enforce their own role.
revoke all on function gac_private.payment_check_pending(uuid,integer,uuid),gac_private.payment_number_free(uuid,integer,uuid),gac_private.guard_payment_reserved_number(),gac_private.finish_payment_allocation(uuid)from public,anon,authenticated;
revoke all on function public.gac_choose_paid_replacements(uuid,text,integer[]),public.gac_expired_unchecked_checkouts(),public.gac_mark_payment_expiry_checked(uuid[],timestamptz)from public,anon,authenticated;
grant execute on function public.gac_choose_paid_replacements(uuid,text,integer[]),public.gac_expired_unchecked_checkouts(),public.gac_mark_payment_expiry_checked(uuid[],timestamptz)to service_role;
revoke all on function public.gac_my_payment_allocations(),public.gac_owner_payment_allocations(),public.gac_owner_release_payment_numbers(text)from public,anon;
grant execute on function public.gac_my_payment_allocations(),public.gac_owner_payment_allocations(),public.gac_owner_release_payment_numbers(text)to authenticated;
create or replace function gac_private.release_reversed_order_numbers() returns trigger language plpgsql security definer set search_path='' as $$
declare c public.gac_collections; removed integer;
begin
 if new.payment_status not in ('voided','refunded') or new.numbers_released_at is not null or exists(select 1 from gac_private.payment_allocations a join gac_private.authorizenet_checkouts i on i.id=a.checkout_id where i.order_id=new.id and a.manual_release_required) then return new;end if;
 select * into c from public.gac_collections where id=new.collection_id for update;
 if c.state<>'open' or c.archived_at is not null or c.recognition_at<=clock_timestamp()
 or exists(select 1 from gac_private.recognition_entries where collection_id=c.id)
 or exists(select 1 from public.gac_recognitions where collection_id=c.id) then return new;end if;
 -- Exact order ownership prevents a replay from releasing a later purchaser's number.
 -- The immutable order receipt survives removal from the active allocation table.
 delete from public.gac_numbers where order_id=new.id and collection_id=c.id;
 get diagnostics removed=row_count;
 if removed>0 then new.numbers_released_at:=clock_timestamp();end if;
 return new;
end $$;
create function gac_private.update_allocation_reversal()returns trigger language plpgsql security definer set search_path=''as $$
begin
 if new.payment_status='refunded' then update gac_private.payment_allocations a set last_status='refundSettledSuccessfully',state='voided',updated_at=clock_timestamp()from gac_private.authorizenet_checkouts i where i.id=a.checkout_id and i.order_id=new.id and a.manual_release_required and a.released_at is null;end if;return new;
end $$;
revoke all on function gac_private.update_allocation_reversal()from public,anon,authenticated;
create trigger allocation_reversal_after_refund after update of payment_status on public.gac_orders for each row execute function gac_private.update_allocation_reversal();
commit;
