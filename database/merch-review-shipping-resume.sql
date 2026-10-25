begin;
create or replace function public.gac_merch_order_review_session(p_id uuid,p_access_hash text)
returns jsonb language plpgsql security definer set search_path=''as $$
declare o gac_private.merch_orders;
begin
 if(select auth.role())is distinct from 'service_role'then raise exception 'Service access required';end if;
 select * into strict o from gac_private.merch_orders where id=p_id and access_hash=p_access_hash;
 return jsonb_build_object(
  'id',o.id,'invoice',o.invoice,
  'state',case when o.state='pending'and o.expires_at<=clock_timestamp()then 'expired'else o.state end,
  'total_cents',o.total_cents,'subtotal_cents',o.subtotal_cents,
  'shipping_cents',o.shipping_cents,'tax_cents',o.tax_cents,
  'tax_rate_bps',o.tax_rate_bps,'tax_jurisdiction',o.tax_jurisdiction,
  'expires_at',o.expires_at,'lines',o.lines,'transaction',o.transaction_id,'note',o.note,
  'shipping',o.shipping,'payment_session_issued',o.token_claimed_at is not null or o.token is not null
 );
end $$;
revoke all on function public.gac_merch_order_review_session(uuid,text)from public,anon,authenticated;
grant execute on function public.gac_merch_order_review_session(uuid,text)to service_role;
notify pgrst,'reload schema';
commit;
