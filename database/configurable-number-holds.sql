begin;
alter table public.gac_collections add column hold_minutes integer not null default 10 check(hold_minutes between 1 and 60);
create or replace function public.gac_hold_number(p_collection uuid,p_number integer)
returns uuid language plpgsql security definer set search_path='' as $$
declare c public.gac_collections; t timestamptz; deadline timestamptz; token uuid;
begin
 if auth.uid() is null or not (public.gac_is_member() or public.gac_is_owner()) then raise exception 'Active verified membership required' using errcode='42501';end if;
 select * into strict c from public.gac_collections where id=p_collection for update;
 t:=clock_timestamp();
 if c.is_test and not public.gac_is_owner() then raise exception 'Owner-only test collection' using errcode='42501';end if;
 if c.archived_at is not null or c.state<>'open' or c.release_at>t or (c.recognition_at is not null and c.recognition_at<=t) then raise exception 'Collection is not open';end if;
 if p_number is null or p_number<1 or p_number>c.quantity then raise exception 'Invalid number';end if;
 delete from gac_private.number_holds where collection_id=c.id and expires_at<=t;
 if exists(select 1 from public.gac_numbers where collection_id=c.id and edition_number=p_number) then raise exception 'This number is already purchased. Choose another number.';end if;
 select hold_id into token from gac_private.number_holds where collection_id=c.id and edition_number=p_number and user_id=auth.uid();
 if found then return token;end if;
 if exists(select 1 from gac_private.number_holds where collection_id=c.id and edition_number=p_number) then raise exception 'Another member just reserved this number. Choose another number.';end if;
 select coalesce(min(expires_at),t+make_interval(mins=>c.hold_minutes)) into deadline from gac_private.number_holds where collection_id=c.id and user_id=auth.uid();
 deadline:=least(deadline,coalesce(c.recognition_at,deadline));
 insert into gac_private.number_holds(collection_id,edition_number,user_id,expires_at) values(c.id,p_number,auth.uid(),deadline) returning hold_id into token;
 return token;
end $$;

commit;
