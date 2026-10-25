create or replace function public.gac_merch_order_session(p_id uuid,p_access_hash text,p_token text default null)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare o gac_private.merch_orders;
begin
 if (select auth.role()) is distinct from 'service_role' then raise exception 'Service access required'; end if;
 select * into strict o from gac_private.merch_orders where id=p_id and access_hash=p_access_hash for update;
 if p_token is not null then
  if o.state<>'pending' or o.expires_at<=clock_timestamp() or char_length(p_token)>10000 then raise exception 'Order cannot accept a token'; end if;
  update gac_private.merch_orders set token=p_token where id=o.id;
  return '{}'::jsonb;
 end if;
 if o.state='pending' and o.expires_at>clock_timestamp() and o.token is null then
  if o.token_claimed_at>clock_timestamp()-interval '45 seconds' then raise exception 'Checkout is being prepared'; end if;
  update gac_private.merch_orders set token_claimed_at=clock_timestamp() where id=o.id;
 end if;
 return jsonb_build_object(
  'id',o.id,
  'invoice',o.invoice,
  'state',case when o.state='pending' and o.expires_at<=clock_timestamp() then 'expired' else o.state end,
  'total_cents',o.total_cents,
  'subtotal_cents',o.subtotal_cents,
  'shipping_cents',o.shipping_cents,
  'tax_cents',o.tax_cents,
  'tax_rate_bps',o.tax_rate_bps,
  'tax_jurisdiction',o.tax_jurisdiction,
  'expires_at',o.expires_at,
  'payment_checked_at',o.payment_checked_at,
  'lines',o.lines,
  'transaction',o.transaction_id,
  'token',case when o.state='pending' and o.expires_at>clock_timestamp() then o.token else null end,
  'note',o.note
 );
end
$$;
revoke all on function public.gac_merch_order_session(uuid,text,text) from public,anon,authenticated;
grant execute on function public.gac_merch_order_session(uuid,text,text) to service_role;
