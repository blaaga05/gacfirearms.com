begin;
-- Refunds must identify the original payment, not only a supplied invoice.
create or replace function public.gac_merch_refund_order(p_reference text,p_invoice text)returns uuid language plpgsql stable security definer set search_path=''as $$
declare o gac_private.merch_orders;
begin
 if(select auth.role())is distinct from 'service_role'then raise exception 'Service access required';end if;
 select * into o from gac_private.merch_orders where transaction_id=p_reference;if not found then return null;end if;
 if p_invoice is not null and p_invoice<>o.invoice then raise exception 'Refund invoice mismatch';end if;return o.id;
end $$;
revoke all on function public.gac_merch_refund_order(text,text)from public,anon,authenticated;
grant execute on function public.gac_merch_refund_order(text,text)to service_role;
commit;
