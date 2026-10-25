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
  'expires_at',o.expires_at,'lines',o.lines,'transaction',o.transaction_id,'note',o.note
 );
end $$;
revoke all on function public.gac_merch_order_review_session(uuid,text)from public,anon,authenticated;
grant execute on function public.gac_merch_order_review_session(uuid,text)to service_role;
create or replace function public.gac_cancel_merch_order_if_unclaimed(p_id uuid,p_access_hash text)
returns jsonb language plpgsql security definer set search_path=''as $$
declare o gac_private.merch_orders;
begin
 if(select auth.role())is distinct from 'service_role'then raise exception 'Service access required';end if;
 update gac_private.merch_orders set state='cancelled'
  where id=p_id and access_hash=p_access_hash and state='pending'and token_claimed_at is null;
 select * into strict o from gac_private.merch_orders where id=p_id and access_hash=p_access_hash;
 return jsonb_build_object('cancelled',o.state='cancelled','state',case when o.state='pending'and o.expires_at<=clock_timestamp()then 'expired'else o.state end,'expires_at',o.expires_at,'payment_checked_at',o.payment_checked_at,'transaction',o.transaction_id);
end $$;
revoke all on function public.gac_cancel_merch_order_if_unclaimed(uuid,text)from public,anon,authenticated;
grant execute on function public.gac_cancel_merch_order_if_unclaimed(uuid,text)to service_role;
create or replace function public.gac_begin_merch_checkout_from_cart(p_id uuid,p_access_hash text,p_client_hash text,p_cart jsonb,p_shipping jsonb,p_tax_bps integer)
returns jsonb language plpgsql security definer set search_path=''as $$
declare c gac_private.merch_carts;result jsonb;existing gac_private.merch_orders;expected integer;actual integer;
begin
 if(select auth.role())is distinct from 'service_role'then raise exception 'Service access required';end if;
 if p_id is null or p_access_hash is null or p_access_hash!~'^[a-f0-9]{64}$'or p_cart is null or jsonb_typeof(p_cart)<>'array'or jsonb_array_length(p_cart)>10 then raise exception 'Invalid cart';end if;
 select * into existing from gac_private.merch_orders where id=p_id for update;
 if found then
  if existing.access_hash<>p_access_hash then raise exception 'Invalid order access';end if;
  if existing.shipping<>p_shipping then raise exception 'Delivery details changed. Start a fresh checkout';end if;
  if jsonb_array_length(existing.lines)<>jsonb_array_length(p_cart)or exists(select 1 from jsonb_array_elements(p_cart)x where not exists(select 1 from jsonb_array_elements(existing.lines)l where l->>'id'=x->>'id'and l->>'size'=x->>'size'and(l->>'quantity')::integer=(x->>'quantity')::integer))then raise exception 'Cart changed. Review the updated order before continuing';end if;
  return public.gac_begin_merch_checkout(p_id,p_access_hash,p_client_hash,p_cart,p_shipping,p_tax_bps);
 end if;
 select * into strict c from gac_private.merch_carts where id=p_id for update;
 if c.access_hash<>p_access_hash then raise exception 'Invalid cart access';end if;
 if c.expires_at<=clock_timestamp()then raise exception 'Your cart hold expired. Update your cart to reserve available items again';end if;
 select count(*)into expected from jsonb_array_elements(p_cart);
 select count(*)into actual from gac_private.merch_cart_holds where cart_id=p_id;
 if expected<>actual or exists(select 1 from jsonb_array_elements(p_cart)x where not exists(select 1 from gac_private.merch_cart_holds h where h.cart_id=p_id and h.product_id=(x->>'id')::uuid and h.size=x->>'size'and h.quantity=(x->>'quantity')::integer))then raise exception 'Cart changed. Refresh the cart hold and review again';end if;
 delete from gac_private.merch_cart_holds where cart_id=p_id;
 delete from gac_private.merch_carts where id=p_id;
 result:=public.gac_begin_merch_checkout(p_id,p_access_hash,p_client_hash,p_cart,p_shipping,p_tax_bps);
 update gac_private.merch_orders set expires_at=c.expires_at where id=p_id returning expires_at into c.expires_at;
 return result||jsonb_build_object('expires_at',c.expires_at);
end $$;
revoke all on function public.gac_begin_merch_checkout_from_cart(uuid,text,text,jsonb,jsonb,integer)from public,anon,authenticated;
grant execute on function public.gac_begin_merch_checkout_from_cart(uuid,text,text,jsonb,jsonb,integer)to service_role;
notify pgrst,'reload schema';
commit;
