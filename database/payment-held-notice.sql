begin;
create function public.gac_my_held_payments()
returns table(transaction_id text,collection text,numbers integer[],hold_expires_at timestamptz,server_time timestamptz)
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not (public.gac_is_member() or public.gac_is_owner()) then raise exception 'Membership required' using errcode='42501';end if;
 return query
 select t.transaction_id,c.callsign,i.numbers,case when h.quantity=cardinality(i.numbers) then h.deadline else null end,clock_timestamp()
 from gac_private.authorizenet_checkouts i join public.gac_collections c on c.id=i.collection_id
 join gac_private.gateway_transactions t on t.checkout_id=i.id and t.kind='authCaptureTransaction'
 left join lateral (
 select count(*) as quantity,min(n.expires_at) as deadline from gac_private.number_holds n
 where n.collection_id=i.collection_id and n.user_id=i.user_id and n.hold_id=any(i.hold_ids) and n.edition_number=any(i.numbers)
 and n.expires_at>clock_timestamp() and c.state='open' and c.archived_at is null and c.release_at<=clock_timestamp() and (c.recognition_at is null or c.recognition_at>clock_timestamp())
 ) h on true
 where i.user_id=auth.uid() and i.order_id is null and t.status in ('FDSPendingReview','FDSAuthorizedPendingReview')
 order by t.observed_at desc;
end $$;
revoke all on function public.gac_my_held_payments() from public,anon;
grant execute on function public.gac_my_held_payments() to authenticated;
commit;
