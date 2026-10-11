begin;
alter table public.gac_collections add column spin_count integer not null default 1 check(spin_count between 1 and 200),add column spin_pause_seconds integer not null default 15 check(spin_pause_seconds between 5 and 3600);
alter table public.gac_recognitions add column spin_number integer not null default 1 check(spin_number between 1 and 200);
alter table public.gac_recognition_awards add column spin_number integer not null default 1;
alter table public.gac_messages add column recognition_spin_number integer;
update public.gac_messages set recognition_spin_number=1 where recognition_collection_id is not null;
alter table public.gac_recognition_awards drop constraint gac_recognition_awards_collection_id_fkey;
alter table public.gac_messages drop constraint gac_messages_recognition_collection_id_fkey,drop constraint gac_messages_recognition_collection_id_key;
alter table public.gac_recognitions drop constraint gac_recognitions_pkey,add primary key(collection_id,spin_number),add unique(collection_id,edition_number);
alter table public.gac_recognition_awards drop constraint gac_recognition_awards_pkey,add primary key(collection_id,spin_number),add foreign key(collection_id,spin_number) references public.gac_recognitions(collection_id,spin_number);
alter table public.gac_messages add unique(recognition_collection_id,recognition_spin_number),add foreign key(recognition_collection_id,recognition_spin_number) references public.gac_recognitions(collection_id,spin_number);
create or replace function gac_private.guard_collection_change() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.gac_numbers where collection_id=old.id) and (new.quantity<>old.quantity or new.price_cents<>old.price_cents or new.callsign<>old.callsign) then raise exception 'Create a new callsign group to change numbers, price, or group name after purchases';end if;
 if exists(select 1 from public.gac_recognitions where collection_id=old.id) and (new.state not in ('closed','recognized') or new.recognition_at is distinct from old.recognition_at or new.wheel_settings<>old.wheel_settings or new.spin_count<>old.spin_count or new.spin_pause_seconds<>old.spin_pause_seconds) then raise exception 'Started recognition settings are immutable';end if;
 if old.state='recognized' and new.state<>'recognized' then raise exception 'Completed recognition is immutable';end if;
 if coalesce((new.wheel_settings->>'rpm')::numeric,0) not between 30 and 180 or coalesce((new.wheel_settings->>'duration')::numeric,0) not between 5 and 30 or coalesce((new.wheel_settings->>'power')::numeric,0) not in (2,3,5) or coalesce((new.wheel_settings->>'idle')::numeric,-1) not between 0 and 6 then raise exception 'Invalid wheel settings';end if;
 if new.spin_count>new.quantity then raise exception 'Spin count cannot exceed the number pool';end if;
 return new;
end $$;
create or replace function gac_private.guard_collection_archive() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.archived_at is not null then
 if exists(select 1 from public.gac_numbers where collection_id=new.id) and new.state<>'recognized' then raise exception 'Complete recognition before removing a group with purchased numbers';end if;
 if new.state='open' then new.state:='closed';end if;new.auto_spin:=false;
 end if;return new;
end $$;
create or replace function gac_private.validate_collection_state() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.state='recognized' and (select count(*) from public.gac_recognitions where collection_id=new.id)<least(new.spin_count,(select count(*) from public.gac_numbers where collection_id=new.id)) then raise exception 'Recognition state is set by the server after the sequence completes';end if;
 if new.state='recognized' and not exists(select 1 from public.gac_recognitions where collection_id=new.id) then raise exception 'Recognition state is set by the server after a number is selected';end if;
 return new;
end $$;
create or replace function gac_private.save_recognition_artwork() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.gac_recognition_awards(collection_id,spin_number,user_id,group_callsign,member_callsign,edition_number,artwork_path,selected_at,reveal_at,is_test,wallpaper_path)
 select new.collection_id,new.spin_number,new.member_id,c.callsign,new.selected_callsign,new.edition_number,c.artwork_path,new.selected_at,new.selected_at+make_interval(secs=>coalesce((c.wheel_settings->>'duration')::integer,14)),c.is_test,(select wallpaper_path from public.gac_recognition_settings where singleton) from public.gac_collections c where c.id=new.collection_id;
 return new;
end $$;
create or replace function gac_private.recognition_message() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.gac_messages(member_id,sender_kind,body,available_at,recognition_collection_id,recognition_spin_number)
 values(new.user_id,'system',(case when new.is_test then 'TEST · ' else '' end)||'Congrats! Your callsign '||new.member_callsign||' has received GAC recognition for '||new.group_callsign||' · #'||new.edition_number||' · Spin '||new.spin_number||'. Your artwork and phone wallpaper are saved in My recognition. Reply here to talk directly with GAC.',new.reveal_at,new.collection_id,new.spin_number) on conflict(recognition_collection_id,recognition_spin_number) do nothing;
 return new;
end $$;
create or replace function public.gac_draw_due_collection(p_collection uuid) returns public.gac_recognitions language plpgsql security definer set search_path='' as $$
declare c public.gac_collections;result public.gac_recognitions; n integer;sample bigint;ceiling bigint;bytes bytea;chosen gac_private.recognition_entries;round_number integer;
begin
 select * into strict c from public.gac_collections where id=p_collection for update;
 select * into result from public.gac_recognitions where collection_id=p_collection order by spin_number desc limit 1;
 if found then
 if c.state='recognized' or result.spin_number>=c.spin_count or now()<result.selected_at+make_interval(secs=>(c.wheel_settings->>'duration')::integer+c.spin_pause_seconds) then return result;end if;
 elsif c.state not in ('open','closed') or c.recognition_at is null or c.recognition_at>now() then raise exception 'Collection is not due';end if;
 if result.collection_id is null then
 insert into gac_private.recognition_entries(collection_id,edition_number,member_id,callsign_snapshot)
 select ent.collection_id,ent.edition_number,ent.user_id,p.callsign from public.gac_numbers ent join public.gac_profiles p on p.user_id=ent.user_id where ent.collection_id=p_collection on conflict do nothing;
 end if;
 select count(*) into n from gac_private.recognition_entries e where e.collection_id=p_collection and not exists(select 1 from public.gac_recognitions r where r.collection_id=e.collection_id and r.edition_number=e.edition_number);
 if n=0 then raise exception 'No eligible purchased numbers';end if;
 round_number:=coalesce(result.spin_number,0)+1;
 ceiling:=4294967296-(4294967296 % n);
 loop bytes:=extensions.gen_random_bytes(4);sample:=get_byte(bytes,0)::bigint*16777216+get_byte(bytes,1)::bigint*65536+get_byte(bytes,2)::bigint*256+get_byte(bytes,3)::bigint;exit when sample<ceiling;end loop;
 select * into strict chosen from gac_private.recognition_entries e where e.collection_id=p_collection and not exists(select 1 from public.gac_recognitions r where r.collection_id=e.collection_id and r.edition_number=e.edition_number) order by e.edition_number offset(sample%n) limit 1;
 insert into public.gac_recognitions(collection_id,spin_number,edition_number,member_id,selected_callsign,eligible_number_count) values(p_collection,round_number,chosen.edition_number,chosen.member_id,chosen.callsign_snapshot,n) returning * into result;
 update public.gac_collections set state=case when round_number>=c.spin_count or n=1 then 'recognized' else 'closed' end where id=p_collection;
 return result;
end $$;
create or replace function public.gac_owner_draw(p_collection uuid) returns public.gac_recognitions language plpgsql security definer set search_path='' as $$
begin
 if not public.gac_is_owner() then raise exception 'Owner access required' using errcode='42501';end if;
 if exists(select 1 from public.gac_recognitions where collection_id=p_collection) then return public.gac_draw_due_collection(p_collection);end if;
 update public.gac_collections set recognition_at=now() where id=p_collection and state in ('open','closed') and archived_at is null;
 if not found then raise exception 'Open or close this collection before recognizing a number';end if;
 return public.gac_draw_due_collection(p_collection);
end $$;
create or replace function gac_private.run_due_recognitions() returns void language plpgsql security definer set search_path='' as $$
declare c record;begin
 for c in select id from public.gac_collections where archived_at is null and state in ('open','closed') and recognition_at<=now() and (auto_spin or exists(select 1 from public.gac_recognitions r where r.collection_id=gac_collections.id)) and exists(select 1 from public.gac_numbers n where n.collection_id=gac_collections.id) loop perform public.gac_draw_due_collection(c.id);end loop;
end $$;
-- Keep the old single-result API compatible with cached clients.
create or replace function public.gac_recognition_result(p_collection_id uuid) returns table(edition_number integer,callsign text,selected_at timestamptz,eligible_number_count integer) language plpgsql stable security definer set search_path='' as $$
begin
 if not(public.gac_is_member() or public.gac_is_owner()) then raise exception 'Membership required' using errcode='42501';end if;
 if not exists(select 1 from public.gac_collections c where c.id=p_collection_id and (c.state<>'draft' or public.gac_is_owner()) and(not c.is_test or public.gac_is_owner())) then raise exception 'Collection unavailable';end if;
 return query select r.edition_number,r.selected_callsign,r.selected_at,r.eligible_number_count from public.gac_recognitions r where r.collection_id=p_collection_id order by r.spin_number desc limit 1;
end $$;
create function public.gac_recognition_rounds(p_collection_id uuid) returns table(spin_number integer,edition_number integer,callsign text,selected_at timestamptz,eligible_number_count integer) language plpgsql stable security definer set search_path='' as $$
begin
 if not(public.gac_is_member() or public.gac_is_owner()) then raise exception 'Membership required' using errcode='42501';end if;
 if not exists(select 1 from public.gac_collections c where c.id=p_collection_id and (c.state<>'draft' or public.gac_is_owner()) and(not c.is_test or public.gac_is_owner())) then raise exception 'Collection unavailable';end if;
 return query select r.spin_number,r.edition_number,r.selected_callsign,r.selected_at,r.eligible_number_count from public.gac_recognitions r where r.collection_id=p_collection_id order by r.spin_number;
end $$;
revoke all on function public.gac_recognition_rounds(uuid) from public,anon;
grant execute on function public.gac_recognition_rounds(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
