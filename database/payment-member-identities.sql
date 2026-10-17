begin;
create function public.gac_owner_payment_review_details() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.gac_is_owner() then raise exception 'Owner access required' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(x),'[]'::jsonb) from(
 select r.transaction_id,i.id as checkout_id,i.user_id as member_id,p.callsign,p.full_name,p.contact_email,c.callsign as collection,i.numbers,i.amount_cents,i.currency,i.status as status,r.reason,r.created_at
 from gac_private.authorizenet_payment_reviews r join gac_private.authorizenet_checkouts i on i.id=r.checkout_id join public.gac_profiles p on p.user_id=i.user_id join public.gac_collections c on c.id=i.collection_id
 where r.resolved_at is null order by r.created_at desc limit 100)x);
end $$;
revoke all on function public.gac_owner_payment_review_details() from public,anon;
grant execute on function public.gac_owner_payment_review_details() to authenticated;
commit;
