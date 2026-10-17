begin;
create or replace function public.gac_my_hosted_checkout(p_checkout uuid)returns table(checkout_id uuid,checkout_status text,amount_cents integer,expires_at timestamptz,order_id uuid)language plpgsql security definer set search_path=''as $$
begin
 if auth.uid()is null then raise exception 'Sign in required';end if;
 return query select i.id,case when a.state='protected'then 'protected'when a.state='choosing'then 'replacement'when a.state='voided'then 'voided'when i.status='pending'and i.expires_at<=clock_timestamp()then 'expired'else i.status end,i.amount_cents,i.expires_at,i.order_id from gac_private.authorizenet_checkouts i left join gac_private.payment_allocations a on a.checkout_id=i.id where i.id=p_checkout and i.user_id=auth.uid();
end $$;
commit;
