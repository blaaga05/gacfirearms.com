CREATE OR REPLACE FUNCTION public.gac_owner_close_duplicate_decline(p_transaction text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  r gac_private.authorizenet_payment_reviews;
  i gac_private.authorizenet_checkouts;
  a gac_private.payment_allocations;
  o public.gac_orders;
  successful_status text;
  expected_numbers integer[];
  assigned_numbers integer[];
  successful_count integer;
BEGIN
  IF auth.uid() IS NULL OR NOT public.gac_is_owner() THEN
    RAISE EXCEPTION 'Owner access required' USING errcode='42501';
  END IF;
  IF p_transaction IS NULL OR p_transaction !~ '^[0-9]{1,30}$' THEN
    RAISE EXCEPTION 'Invalid transaction';
  END IF;

  SELECT * INTO STRICT r FROM gac_private.authorizenet_payment_reviews
    WHERE transaction_id=p_transaction FOR UPDATE;
  IF r.resolved_at IS NOT NULL OR r.reason<>'Another payment is already associated with this checkout' THEN
    RAISE EXCEPTION 'This is not an open duplicate-payment decline review';
  END IF;

  SELECT * INTO STRICT i FROM gac_private.authorizenet_checkouts WHERE id=r.checkout_id FOR UPDATE;
  SELECT * INTO STRICT a FROM gac_private.payment_allocations WHERE checkout_id=i.id FOR UPDATE;
  SELECT * INTO STRICT o FROM public.gac_orders WHERE id=i.order_id;

  SELECT status INTO STRICT successful_status FROM gac_private.gateway_transactions
    WHERE checkout_id=i.id AND transaction_id=i.transaction_id
      AND kind='authCaptureTransaction' AND status IN('capturedPendingSettlement','settledSuccessfully')
      AND amount_cents=i.amount_cents;
  SELECT count(*) INTO successful_count FROM gac_private.gateway_transactions
    WHERE checkout_id=i.id AND kind='authCaptureTransaction'
      AND status IN('capturedPendingSettlement','settledSuccessfully');
  SELECT coalesce(array_agg(x ORDER BY x),'{}'::integer[]) INTO expected_numbers FROM unnest(i.numbers) x;
  SELECT coalesce(array_agg(n.edition_number ORDER BY n.edition_number),'{}'::integer[])
    INTO assigned_numbers FROM public.gac_numbers n WHERE n.order_id=o.id;

  IF p_transaction=i.transaction_id OR i.status<>'credited' OR i.order_id IS NULL
     OR a.transaction_id IS DISTINCT FROM i.transaction_id
     OR a.state NOT IN('manual_review','fulfilled')
     OR a.selected_numbers IS DISTINCT FROM expected_numbers
     OR o.payment_reference IS DISTINCT FROM 'AUTHNET-'||i.transaction_id
     OR o.user_id IS DISTINCT FROM i.user_id OR o.collection_id IS DISTINCT FROM i.collection_id
     OR o.amount_cents IS DISTINCT FROM i.amount_cents OR o.numbers_released_at IS NOT NULL
     OR assigned_numbers IS DISTINCT FROM expected_numbers
     OR successful_count<>1
     OR NOT EXISTS(SELECT 1 FROM gac_private.gateway_transactions g
       WHERE g.checkout_id=i.id AND g.transaction_id=p_transaction
         AND g.kind='authCaptureTransaction' AND g.status='declined'
         AND g.amount_cents=i.amount_cents)
     OR EXISTS(SELECT 1 FROM gac_private.payment_reservations pr WHERE pr.checkout_id=i.id)
     OR NOT EXISTS(SELECT 1 FROM gac_private.payment_allocation_events e
       WHERE e.checkout_id=i.id AND e.kind='fulfilled') THEN
    RAISE EXCEPTION 'The declined attempt is not a safe duplicate of one verified, credited payment';
  END IF;

  UPDATE gac_private.payment_allocations SET state='fulfilled',last_status=successful_status,
    manual_release_required=false,updated_at=clock_timestamp() WHERE checkout_id=i.id;
  UPDATE gac_private.authorizenet_payment_reviews SET resolved_at=clock_timestamp(),
    resolution='Declined repeat attempt closed; a separate successful payment was already credited. No order, number, or wheel changes.'
    WHERE transaction_id=p_transaction AND checkout_id=i.id AND resolved_at IS NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.gac_owner_close_duplicate_decline(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gac_owner_close_duplicate_decline(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.gac_owner_close_duplicate_decline(text) TO authenticated;
COMMENT ON FUNCTION public.gac_owner_close_duplicate_decline(text) IS
  'Closes a declined repeat attempt only when exactly one successful payment is already credited to the same checkout and all purchased numbers remain intact.';

