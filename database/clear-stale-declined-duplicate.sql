CREATE OR REPLACE FUNCTION gac_private.clear_stale_declined_duplicate(p_transaction text,p_actor uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  a gac_private.payment_allocations;
  i gac_private.authorizenet_checkouts;
  o public.gac_orders;
  successful_status text;
  expected_numbers integer[];
  assigned_numbers integer[];
  successful_count integer;
BEGIN
  IF p_transaction IS NULL OR p_transaction !~ '^[0-9]{1,30}$' THEN
    RETURN false;
  END IF;

  SELECT * INTO a FROM gac_private.payment_allocations
    WHERE transaction_id=p_transaction FOR UPDATE;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  IF a.state='fulfilled' AND a.last_status IN('capturedPendingSettlement','settledSuccessfully') THEN
    RETURN true;
  END IF;
  IF a.state<>'manual_review' OR a.last_status<>'declined' OR a.released_at IS NOT NULL THEN
    RETURN false;
  END IF;

  SELECT * INTO i FROM gac_private.authorizenet_checkouts
    WHERE id=a.checkout_id FOR UPDATE;
  IF NOT FOUND OR i.status<>'credited' OR i.order_id IS NULL OR i.transaction_id IS DISTINCT FROM p_transaction THEN
    RETURN false;
  END IF;
  SELECT * INTO o FROM public.gac_orders WHERE id=i.order_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  SELECT g.status INTO successful_status
  FROM gac_private.gateway_transactions g
  WHERE g.checkout_id=i.id AND g.transaction_id=p_transaction
    AND g.kind='authCaptureTransaction'
    AND g.status IN('capturedPendingSettlement','settledSuccessfully')
    AND g.amount_cents=i.amount_cents;
  IF successful_status IS NULL THEN
    RETURN false;
  END IF;

  SELECT count(*) INTO successful_count
  FROM gac_private.gateway_transactions g
  WHERE g.checkout_id=i.id AND g.kind='authCaptureTransaction'
    AND g.status IN('capturedPendingSettlement','settledSuccessfully');

  SELECT coalesce(array_agg(x ORDER BY x),'{}'::integer[])
    INTO expected_numbers FROM unnest(i.numbers) x;
  SELECT coalesce(array_agg(n.edition_number ORDER BY n.edition_number),'{}'::integer[])
    INTO assigned_numbers FROM public.gac_numbers n WHERE n.order_id=o.id;

  IF i.order_id IS NULL
     OR a.transaction_id IS DISTINCT FROM p_transaction
     OR a.selected_numbers IS DISTINCT FROM expected_numbers
     OR o.payment_reference IS DISTINCT FROM 'AUTHNET-'||p_transaction
     OR o.user_id IS DISTINCT FROM i.user_id
     OR o.collection_id IS DISTINCT FROM i.collection_id
     OR o.amount_cents IS DISTINCT FROM i.amount_cents
     OR o.numbers_released_at IS NOT NULL
     OR assigned_numbers IS DISTINCT FROM expected_numbers
     OR successful_count<>1
     OR NOT EXISTS(
       SELECT 1 FROM gac_private.gateway_transactions g
       WHERE g.checkout_id=i.id AND g.transaction_id<>p_transaction
         AND g.kind='authCaptureTransaction' AND g.status='declined'
         AND g.amount_cents=i.amount_cents
     )
     OR EXISTS(SELECT 1 FROM gac_private.payment_reservations pr WHERE pr.checkout_id=i.id)
     OR NOT EXISTS(SELECT 1 FROM gac_private.payment_allocation_events e WHERE e.checkout_id=i.id AND e.kind='fulfilled') THEN
    RETURN false;
  END IF;

  UPDATE gac_private.payment_allocations
  SET state='fulfilled',last_status=successful_status,manual_release_required=false,updated_at=clock_timestamp()
  WHERE checkout_id=i.id;

  UPDATE gac_private.authorizenet_payment_reviews r
  SET resolved_at=clock_timestamp(),
      resolution='Declined repeat attempt closed; one successful payment is already credited. Existing numbers and order were preserved.'
  WHERE r.checkout_id=i.id AND r.resolved_at IS NULL
    AND r.reason='Another payment is already associated with this checkout'
    AND EXISTS(
      SELECT 1 FROM gac_private.gateway_transactions g
      WHERE g.checkout_id=i.id AND g.transaction_id=r.transaction_id
        AND g.kind='authCaptureTransaction' AND g.status='declined'
    );

  INSERT INTO gac_private.payment_allocation_events(checkout_id,kind,numbers,actor)
  VALUES(i.id,'declined_duplicate_cleared',expected_numbers,p_actor);

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION gac_private.clear_stale_declined_duplicate(text,uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.gac_owner_clear_stale_declined_duplicate(p_transaction text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT public.gac_is_owner() THEN
    RAISE EXCEPTION 'Owner access required' USING errcode='42501';
  END IF;
  IF NOT gac_private.clear_stale_declined_duplicate(p_transaction,auth.uid()) THEN
    RAISE EXCEPTION 'This declined item is not a safe duplicate of an already credited payment. No numbers were changed.';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.gac_owner_clear_stale_declined_duplicate(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.gac_owner_clear_stale_declined_duplicate(text) TO authenticated;
COMMENT ON FUNCTION public.gac_owner_clear_stale_declined_duplicate(text) IS
  'Closes a stale declined repeat only after confirming exactly one successful capture is credited and the existing order still owns all selected numbers. Never releases numbers.';

DO $repair$
BEGIN
  PERFORM gac_private.clear_stale_declined_duplicate('81907837294',NULL);
END;
$repair$;
