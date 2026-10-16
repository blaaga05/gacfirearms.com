begin;
create table gac_private.authorizenet_checkouts (
 id uuid primary key default extensions.gen_random_uuid(),request_id uuid not null unique,
 invoice text not null unique default ('GAC'||substr(replace(extensions.gen_random_uuid()::text,'-',''),1,17)),
 user_id uuid not null references public.gac_profiles(user_id),collection_id uuid not null references public.gac_collections(id),
 numbers integer[] not null,hold_ids uuid[] not null,amount_cents integer not null check(amount_cents>0),currency text not null check(currency='usd'),
 acknowledgment text not null,callsign text not null,created_at timestamptz not null default clock_timestamp(),expires_at timestamptz not null,
 status text not null default 'pending' check(status in('pending','credited','review','expired')),
 token text,token_claimed_at timestamptz,transaction_id text unique,order_id uuid references public.gac_orders(id),review_reason text
);
alter table gac_private.authorizenet_checkouts enable row level security;
revoke all on gac_private.authorizenet_checkouts from public,anon,authenticated;
create index authorizenet_checkouts_member on gac_private.authorizenet_checkouts(user_id,created_at desc);
create table gac_private.authorizenet_payment_reviews(
 transaction_id text primary key check(transaction_id~'^[0-9]{1,30}$'),checkout_id uuid references gac_private.authorizenet_checkouts(id),reason text not null,
 created_at timestamptz not null default clock_timestamp(),resolved_at timestamptz,resolution text
);
alter table gac_private.authorizenet_payment_reviews enable row level security;
revoke all on gac_private.authorizenet_payment_reviews from public,anon,authenticated;
create function public.gac_begin_hosted_checkout(p_collection uuid,p_numbers integer[],p_acknowledged boolean,p_request uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare c public.gac_collections;p public.gac_profiles;i gac_private.authorizenet_checkouts;nums integer[];tokens uuid[];deadline timestamptz;
begin
 -- Owner pilot is enforced server-side. Member rollout requires a separate change.
 if auth.uid() is null or not public.gac_is_owner() then raise exception 'Hosted checkout is in owner testing' using errcode='42501';end if;
 if p_acknowledged is distinct from true or p_request is null then raise exception 'Purchase acknowledgment required';end if;
 select * into strict c from public.gac_collections where id=p_collection for update;
 if c.is_test or c.archived_at is not null or c.state<>'open' or c.release_at>clock_timestamp() or c.recognition_at<=clock_timestamp() then raise exception 'Choose an open live collection';end if;
 select * into strict p from public.gac_profiles where user_id=auth.uid();
 if p.status<>'active' or not exists(select 1 from auth.users where id=p.user_id and email_confirmed_at is not null) then raise exception 'Active verified membership required';end if;
 select array_agg(x order by x) into nums from unnest(p_numbers)x;
 if coalesce(cardinality(nums),0)<1 or cardinality(nums)>200 or (select count(distinct x) from unnest(nums)x)<>cardinality(nums) then raise exception 'Select distinct numbers';end if;
 select * into i from gac_private.authorizenet_checkouts where request_id=p_request;
 if found then
  if i.user_id<>p.user_id or i.collection_id<>c.id or i.numbers is distinct from nums then raise exception 'Checkout request conflict';end if;
  if i.status<>'pending' or i.expires_at<=clock_timestamp() then raise exception 'This checkout expired or has already been processed';end if;
  return i.id;
 end if;
 select * into i from gac_private.authorizenet_checkouts where user_id=p.user_id and collection_id=c.id and status='pending' and expires_at>clock_timestamp() order by created_at desc limit 1;
 if found then
  if i.numbers is distinct from nums then raise exception 'An earlier checkout is still open. Finish it or wait for its hold to expire before changing this cart.';end if;
  return i.id;
 end if;
 select array_agg(h.hold_id order by h.edition_number),min(h.expires_at) into tokens,deadline from gac_private.number_holds h where h.collection_id=c.id and h.user_id=p.user_id and h.edition_number=any(nums) and h.expires_at>clock_timestamp();
 if coalesce(cardinality(tokens),0)<>cardinality(nums) or exists(select 1 from unnest(nums)x where x<1 or x>c.quantity) or exists(select 1 from public.gac_numbers where collection_id=c.id and edition_number=any(nums)) then raise exception 'Your number holds changed. Refresh and select available numbers again.';end if;
 if deadline<clock_timestamp()+interval '90 seconds' then raise exception 'Less than 90 seconds remains on your hold. Wait for it to expire, then select numbers again.';end if;
 insert into gac_private.authorizenet_checkouts(request_id,user_id,collection_id,numbers,hold_ids,amount_cents,currency,acknowledgment,callsign,expires_at)
 values(p_request,p.user_id,c.id,nums,tokens,c.price_cents*cardinality(nums),c.currency,(select recognition_statement from public.gac_requirements where singleton),p.callsign,deadline) returning id into i.id;
 return i.id;
end $$;
create function public.gac_hosted_checkout_token(p_checkout uuid,p_member uuid,p_token text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare i gac_private.authorizenet_checkouts;
begin
 if (select auth.role()) is distinct from 'service_role' then raise exception 'Service access required';end if;
 select * into strict i from gac_private.authorizenet_checkouts where id=p_checkout and user_id=p_member for update;
 if i.status<>'pending' or i.expires_at<=clock_timestamp() then raise exception 'Checkout expired';end if;
 if p_token is not null then
  if length(p_token)>10000 or length(p_token)<10 then raise exception 'Invalid token';end if;
  update gac_private.authorizenet_checkouts set token=coalesce(token,p_token) where id=i.id;
  return '{}'::jsonb;
 end if;
 if i.token is null then
  if i.token_claimed_at>clock_timestamp()-interval '45 seconds' then raise exception 'Checkout is being prepared. Try again shortly.';end if;
  update gac_private.authorizenet_checkouts set token_claimed_at=clock_timestamp() where id=i.id;
 end if;
 return jsonb_build_object('id',i.id,'invoice',i.invoice,'member',i.user_id,'amount_cents',i.amount_cents,'currency',i.currency,'token',i.token,'expires_at',i.expires_at);
end $$;
create function public.gac_apply_authorizenet_payment(p_transaction text,p_invoice text,p_amount_cents integer,p_paid_at timestamptz,p_status text,p_currency text default 'usd')
returns text language plpgsql security definer set search_path='' as $$
declare i gac_private.authorizenet_checkouts;c public.gac_collections;oid uuid;reason text;existing uuid;
begin
 if (select auth.role()) is distinct from 'service_role' then raise exception 'Service access required';end if;
 if p_transaction!~'^[0-9]{1,30}$' then raise exception 'Invalid transaction';end if;
 select * into i from gac_private.authorizenet_checkouts where invoice=p_invoice;
 if not found then return 'unrelated';end if;
 select * into strict c from public.gac_collections where id=i.collection_id for update;
 select * into strict i from gac_private.authorizenet_checkouts where id=i.id for update;
 select id into existing from public.gac_orders where payment_reference='AUTHNET-'||p_transaction;
 if existing is not null then
  if i.order_id=existing then return 'credited';else raise exception 'Transaction already used';end if;
 end if;
 if i.status='credited' then reason:='Another transaction was already credited to this checkout';
 elsif p_status is null or p_status not in ('capturedPendingSettlement','settledSuccessfully') then reason:='Transaction status: '||p_status;
 elsif p_amount_cents is distinct from i.amount_cents or lower(p_currency) is distinct from i.currency then reason:='Payment amount or currency mismatch';
 elsif p_paid_at is null or p_paid_at<i.created_at-interval '1 minute' or p_paid_at>clock_timestamp()+interval '1 minute' then reason:='Payment timestamp mismatch';
 elsif i.expires_at<=clock_timestamp() then reason:='Payment arrived after the checkout hold expired';
 elsif c.is_test or c.archived_at is not null or c.state<>'open' or c.release_at>clock_timestamp() or c.recognition_at<=clock_timestamp() or exists(select 1 from public.gac_recognitions where collection_id=c.id) then reason:='Collection is no longer open for crediting';
 elsif not exists(select 1 from public.gac_profiles where user_id=i.user_id and status='active') then reason:='Membership is no longer active';
 elsif exists(select 1 from public.gac_numbers where collection_id=c.id and edition_number=any(i.numbers)) then reason:='A requested number is already assigned';
 elsif (select array_agg(hold_id order by edition_number) from gac_private.number_holds where collection_id=c.id and user_id=i.user_id and edition_number=any(i.numbers) and expires_at>clock_timestamp()) is distinct from i.hold_ids then reason:='The original number holds were changed or released';
 end if;
 if reason is not null then
  insert into gac_private.authorizenet_payment_reviews(transaction_id,checkout_id,reason)values(p_transaction,i.id,reason) on conflict(transaction_id) do update set reason=excluded.reason;
  if i.status<>'credited' then update gac_private.authorizenet_checkouts set status='review',review_reason=reason,token=null where id=i.id;end if;
  return 'review';
 end if;
 insert into public.gac_orders(user_id,collection_id,payment_reference,amount_cents,currency,paid_at,acknowledgment,acknowledged_at)
 values(i.user_id,i.collection_id,'AUTHNET-'||p_transaction,i.amount_cents,i.currency,p_paid_at,i.acknowledgment,i.created_at) returning id into oid;
 insert into public.gac_numbers(collection_id,edition_number,order_id,user_id,callsign_at_purchase)select i.collection_id,x,oid,i.user_id,i.callsign from unnest(i.numbers)x;
 delete from gac_private.number_holds where collection_id=c.id and user_id=i.user_id and hold_id=any(i.hold_ids);
 update gac_private.authorizenet_payment_reviews set resolved_at=clock_timestamp(),resolution='Verified and credited' where transaction_id=p_transaction;
 update gac_private.authorizenet_checkouts set status='credited',transaction_id=p_transaction,order_id=oid,token=null where id=i.id;
 return 'credited';
end $$;
create function public.gac_my_hosted_checkout(p_checkout uuid)
returns table(checkout_id uuid,checkout_status text,amount_cents integer,expires_at timestamptz,order_id uuid)
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in required';end if;
 return query select i.id,case when i.status='pending' and i.expires_at<=clock_timestamp() then 'expired' else i.status end,i.amount_cents,i.expires_at,i.order_id from gac_private.authorizenet_checkouts i where i.id=p_checkout and i.user_id=auth.uid();
end $$;
create function public.gac_owner_payment_reviews()
returns table(transaction_id text,checkout_id uuid,callsign text,contact_email text,collection text,amount_cents integer,reason text,created_at timestamptz)
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.gac_is_owner() then raise exception 'Owner access required';end if;
 return query select r.transaction_id,i.id,p.callsign,p.contact_email,c.callsign,i.amount_cents,r.reason,r.created_at from gac_private.authorizenet_payment_reviews r join gac_private.authorizenet_checkouts i on i.id=r.checkout_id join public.gac_profiles p on p.user_id=i.user_id join public.gac_collections c on c.id=i.collection_id where r.resolved_at is null order by r.created_at desc limit 100;
end $$;
create function public.gac_finish_authorizenet_notification(p_notification uuid,p_outcome text)
returns void language plpgsql security definer set search_path='' as $$
begin
 if (select auth.role()) is distinct from 'service_role' then raise exception 'Service access required';end if;
 update gac_private.authorizenet_notifications set processed_at=clock_timestamp(),processing_status=p_outcome where notification_id=p_notification;
end $$;
create function public.gac_resolve_payment_review(p_transaction text,p_resolution text)
returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.gac_is_owner() then raise exception 'Owner access required';end if;
 if length(trim(p_resolution)) not between 10 and 1000 then raise exception 'Describe the resolution in 10–1000 characters';end if;
 update gac_private.authorizenet_payment_reviews set resolved_at=clock_timestamp(),resolution=trim(p_resolution) where transaction_id=p_transaction;
end $$;
revoke all on function public.gac_resolve_payment_review(text,text) from public,anon;
grant execute on function public.gac_resolve_payment_review(text,text) to authenticated;
create function public.gac_pending_authorizenet_notifications()
returns table(notification_id uuid,transaction_id text) language plpgsql security definer set search_path='' as $$
begin
 if (select auth.role()) is distinct from 'service_role' then raise exception 'Service access required';end if;
 return query select n.notification_id,n.transaction_id from gac_private.authorizenet_notifications n where n.processed_at is null order by n.received_at desc limit 10;
end $$;
revoke all on function public.gac_pending_authorizenet_notifications() from public,anon,authenticated;
grant execute on function public.gac_pending_authorizenet_notifications() to service_role;
revoke all on function public.gac_begin_hosted_checkout(uuid,integer[],boolean,uuid),public.gac_my_hosted_checkout(uuid),public.gac_owner_payment_reviews() from public,anon;
grant execute on function public.gac_begin_hosted_checkout(uuid,integer[],boolean,uuid),public.gac_my_hosted_checkout(uuid),public.gac_owner_payment_reviews() to authenticated;
revoke all on function public.gac_hosted_checkout_token(uuid,uuid,text),public.gac_apply_authorizenet_payment(text,text,integer,timestamptz,text,text),public.gac_finish_authorizenet_notification(uuid,text) from public,anon,authenticated;
grant execute on function public.gac_hosted_checkout_token(uuid,uuid,text),public.gac_apply_authorizenet_payment(text,text,integer,timestamptz,text,text),public.gac_finish_authorizenet_notification(uuid,text) to service_role;
commit;
