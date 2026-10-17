create or replace function gac_private.payment_number_free(p_collection uuid,p_number integer,p_checkout uuid) returns boolean language sql stable security definer set search_path='' as $$
 select p_number between 1 and(select quantity from public.gac_collections where id=p_collection)and not exists(select 1 from public.gac_numbers where collection_id=p_collection and edition_number=p_number)
 and not exists(select 1 from gac_private.payment_reservations where collection_id=p_collection and edition_number=p_number and checkout_id<>p_checkout)
 and not exists(select 1 from gac_private.number_holds h where h.collection_id=p_collection and h.edition_number=p_number and h.expires_at>clock_timestamp() and not exists(select 1 from gac_private.authorizenet_checkouts i where i.id=p_checkout and h.hold_id=any(i.hold_ids)))
 and not gac_private.payment_check_pending(p_collection,p_number,p_checkout);
$$;
