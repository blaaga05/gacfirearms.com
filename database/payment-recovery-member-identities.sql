create or replace function public.gac_owner_recovery_status() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.gac_is_owner() then raise exception 'Owner access required' using errcode='42501';end if;
 return (select jsonb_build_object('last_started_at',last_started_at,'last_success_at',last_success_at,'last_error',last_error,'due_jobs',(select count(*) from gac_private.payment_recovery_queue where next_check_at<=clock_timestamp()),'gateway_activity',(select coalesce(jsonb_agg(a),'[]'::jsonb) from(
 select t.transaction_id,i.user_id as member_id,p.callsign,p.full_name,p.contact_email,c.callsign as collection,i.numbers,i.currency,t.kind,t.status,t.amount_cents,t.observed_at
 from gac_private.gateway_transactions t join gac_private.authorizenet_checkouts i on i.id=t.checkout_id join public.gac_collections c on c.id=i.collection_id join public.gac_profiles p on p.user_id=i.user_id order by t.observed_at desc limit 20)a)) from gac_private.payment_recovery_state where singleton);
end $$;
