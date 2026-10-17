begin;
create or replace function public.gac_my_payment_reviews()returns table(checkout_id uuid,transaction_id text,numbers integer[],collection text,reason text)language plpgsql stable security definer set search_path=''as $$
begin
 if auth.uid()is null or not public.gac_is_member()then raise exception 'Active member access required'using errcode='42501';end if;
 return query select i.id,r.transaction_id,i.numbers,c.callsign,r.reason from gac_private.authorizenet_payment_reviews r join gac_private.authorizenet_checkouts i on i.id=r.checkout_id join public.gac_collections c on c.id=i.collection_id where i.user_id=auth.uid()and r.resolved_at is null and not exists(select 1 from gac_private.payment_allocations a where a.checkout_id=i.id and a.state in('protected','choosing','voided'))order by r.created_at;
end $$;
create function gac_private.invoke_payment_expiry()returns bigint language plpgsql security definer set search_path=''as $$
declare endpoint text;token text;request_id bigint;
begin
 if not exists(select 1 from gac_private.authorizenet_checkouts i where i.token_claimed_at is not null and i.order_id is null and i.expires_at<=clock_timestamp()and coalesce(i.payment_checked_at,'-infinity'::timestamptz)<i.expires_at and not exists(select 1 from gac_private.payment_allocations a where a.checkout_id=i.id))then return null;end if;
 select replace(s.endpoint,'gac-payment-recovery','gac-payment-expiry')into strict endpoint from gac_private.payment_recovery_state s where singleton;
 select decrypted_secret into strict token from vault.decrypted_secrets where name='gac_payment_recovery_token';
 select net.http_post(url:=endpoint,headers:=jsonb_build_object('Content-Type','application/json','x-gac-recovery-token',token),body:='{}'::jsonb,timeout_milliseconds:=100000)into request_id;return request_id;
end $$;
revoke all on function gac_private.invoke_payment_expiry()from public,anon,authenticated;
commit;
