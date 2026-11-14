CREATE OR REPLACE FUNCTION gac_private.guard_collection_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
begin
 if exists(select 1 from public.gac_numbers where collection_id=old.id) and (new.quantity<>old.quantity or new.price_cents<>old.price_cents) then raise exception 'Create a new callsign group to change number quantity or price after purchases';end if;
 if exists(select 1 from public.gac_recognitions where collection_id=old.id) and (new.state not in ('closed','recognized') or new.recognition_at is distinct from old.recognition_at or new.wheel_settings<>old.wheel_settings or new.spin_count<>old.spin_count or new.spin_pause_seconds<>old.spin_pause_seconds) then raise exception 'Started recognition settings are immutable';end if;
 if old.state='recognized' and new.state<>'recognized' then raise exception 'Completed recognition is immutable';end if;
 if coalesce((new.wheel_settings->>'rpm')::numeric,0) not between 30 and 180 or coalesce((new.wheel_settings->>'duration')::numeric,0) not between 5 and 30 or coalesce((new.wheel_settings->>'power')::numeric,0) not in (2,3,5) or coalesce((new.wheel_settings->>'idle')::numeric,-1) not between 0 and 6 then raise exception 'Invalid wheel settings';end if;
 if new.spin_count>new.quantity then raise exception 'Spin count cannot exceed the number pool';end if;
 return new;
end $function$;