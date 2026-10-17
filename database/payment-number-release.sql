-- Run after payment-recovery.sql. Only verified reconciliation updates payment_status.
alter table public.gac_orders add column if not exists purchased_numbers jsonb not null default '[]'::jsonb;
alter table public.gac_orders add column if not exists numbers_released_at timestamptz;
update public.gac_orders o set purchased_numbers=(select coalesce(jsonb_agg(jsonb_build_object('edition_number',n.edition_number,'callsign_at_purchase',n.callsign_at_purchase) order by n.edition_number),'[]'::jsonb) from public.gac_numbers n where n.order_id=o.id) where purchased_numbers='[]'::jsonb;
create or replace function gac_private.record_purchased_number() returns trigger language plpgsql security definer set search_path='' as $$
begin
 update public.gac_orders set purchased_numbers=purchased_numbers || jsonb_build_array(jsonb_build_object('edition_number',new.edition_number,'callsign_at_purchase',new.callsign_at_purchase)) where id=new.order_id;
 return new;
end $$;
revoke all on function gac_private.record_purchased_number() from public,anon,authenticated;
create trigger preserve_number_receipt after insert on public.gac_numbers for each row execute function gac_private.record_purchased_number();
create or replace function gac_private.release_reversed_order_numbers() returns trigger language plpgsql security definer set search_path='' as $$
declare c public.gac_collections; removed integer;
begin
 if new.payment_status not in ('voided','refunded') or new.numbers_released_at is not null then return new;end if;
 select * into c from public.gac_collections where id=new.collection_id for update;
 if c.state<>'open' or c.archived_at is not null or c.recognition_at<=clock_timestamp()
 or exists(select 1 from gac_private.recognition_entries where collection_id=c.id)
 or exists(select 1 from public.gac_recognitions where collection_id=c.id) then return new;end if;
 -- Exact order ownership prevents a replay from releasing a later purchaser's number.
 -- The immutable order receipt survives removal from the active allocation table.
 delete from public.gac_numbers where order_id=new.id and collection_id=c.id;
 get diagnostics removed=row_count;
 if removed>0 then new.numbers_released_at:=clock_timestamp();end if;
 return new;
end $$;
revoke all on function gac_private.release_reversed_order_numbers() from public,anon,authenticated;
create trigger release_verified_reversal before update of payment_status on public.gac_orders for each row execute function gac_private.release_reversed_order_numbers();
-- Apply the same safe rule to reversals already verified before this migration.
update public.gac_orders set payment_status=payment_status where payment_status in ('voided','refunded') and numbers_released_at is null;
