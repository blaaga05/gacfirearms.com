begin;
create function gac_private.guard_payment_collection_settings()returns trigger language plpgsql security definer set search_path=''as $$
begin
 if(new.quantity<>old.quantity or new.price_cents<>old.price_cents or new.callsign<>old.callsign or new.is_test is distinct from old.is_test)and exists(select 1 from gac_private.payment_reservations where collection_id=old.id)then raise exception 'Resolve protected payment numbers before changing collection numbers, price, name, or test mode';end if;return new;
end $$;
revoke all on function gac_private.guard_payment_collection_settings()from public,anon,authenticated;
create trigger payment_collection_settings_guard before update of quantity,price_cents,callsign,is_test on public.gac_collections for each row execute function gac_private.guard_payment_collection_settings();
commit;
