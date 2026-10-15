begin;
create table gac_private.message_settings(singleton boolean primary key default true check(singleton),welcome_enabled boolean not null default true,welcome_body text not null check(length(trim(welcome_body)) between 1 and 2000),updated_at timestamptz not null default now());
insert into gac_private.message_settings(singleton,welcome_body) values(true,'Welcome to GAC! Your member account is ready. Explore the current collections, follow live recognition, and reply here whenever you need help.');
create table gac_private.message_broadcasts(id uuid primary key default extensions.gen_random_uuid(),request_id uuid not null unique,sender_id uuid not null references auth.users(id),body text not null check(length(trim(body)) between 1 and 2000),recipient_count integer not null default 0,created_at timestamptz not null default now());
create index message_broadcast_sender_idx on gac_private.message_broadcasts(sender_id,created_at desc);
alter table gac_private.message_settings enable row level security;
alter table gac_private.message_broadcasts enable row level security;
revoke all on gac_private.message_settings,gac_private.message_broadcasts from public,anon,authenticated;
alter table public.gac_messages add column is_welcome boolean not null default false,add column broadcast_id uuid references gac_private.message_broadcasts(id);
create unique index gac_one_welcome_per_member on public.gac_messages(member_id) where is_welcome;
create unique index gac_one_broadcast_per_member on public.gac_messages(broadcast_id,member_id) where broadcast_id is not null;

create function public.gac_owner_message_settings() returns table(welcome_enabled boolean,welcome_body text,recipient_count bigint)
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.gac_is_owner() then raise exception 'Owner access required' using errcode='42501';end if;
 return query select s.welcome_enabled,s.welcome_body,(select count(*) from public.gac_profiles p join auth.users u on u.id=p.user_id where p.status='active' and u.email_confirmed_at is not null) from gac_private.message_settings s where singleton;
end $$;
create function public.gac_save_welcome_message(p_body text,p_enabled boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.gac_is_owner() then raise exception 'Owner access required' using errcode='42501';end if;
 if p_body is null or length(trim(p_body)) not between 1 and 2000 or p_enabled is null then raise exception 'Enter a welcome message of 1–2000 characters';end if;
 update gac_private.message_settings set welcome_body=trim(p_body),welcome_enabled=p_enabled,updated_at=clock_timestamp() where singleton;
end $$;
create function public.gac_message_all_members(p_body text,p_request uuid) returns integer language plpgsql security definer set search_path='' as $$
declare prior gac_private.message_broadcasts;bid uuid;sent integer;uid uuid:=auth.uid();
begin
 if uid is null or not public.gac_is_owner() then raise exception 'Owner access required' using errcode='42501';end if;
 if p_request is null or p_body is null or length(trim(p_body)) not between 1 and 2000 then raise exception 'Enter a message of 1–2000 characters';end if;
 perform pg_advisory_xact_lock(hashtextextended('gac-broadcast-'||uid::text,0));
 select * into prior from gac_private.message_broadcasts where request_id=p_request;
 if found then
  if prior.sender_id<>uid or prior.body<>trim(p_body) then raise exception 'This send request was already used';end if;
  return prior.recipient_count;
 end if;
 if exists(select 1 from gac_private.message_broadcasts where sender_id=uid and created_at>now()-interval '30 seconds') then raise exception 'Please wait 30 seconds before sending another announcement';end if;
 insert into gac_private.message_broadcasts(request_id,sender_id,body) values(p_request,uid,trim(p_body)) returning id into bid;
 insert into public.gac_messages(member_id,sender_id,sender_kind,body,owner_read_at,broadcast_id)
 select p.user_id,uid,'gac',trim(p_body),now(),bid from public.gac_profiles p join auth.users u on u.id=p.user_id where p.status='active' and u.email_confirmed_at is not null;
 get diagnostics sent=row_count;
 update gac_private.message_broadcasts set recipient_count=sent where id=bid;
 return sent;
end $$;
create function gac_private.welcome_new_member() returns trigger language plpgsql security definer set search_path='' as $$
declare s gac_private.message_settings;
begin
 select * into s from gac_private.message_settings where singleton;
 if not found or not s.welcome_enabled then return new;end if;
 insert into public.gac_messages(member_id,sender_kind,body,is_welcome,owner_read_at) values(new.user_id,'system',s.welcome_body,true,now()) on conflict(member_id) where is_welcome do nothing;
 return new;
end $$;
revoke all on function gac_private.welcome_new_member() from public,anon,authenticated;
create trigger gac_welcome_new_member after insert on public.gac_profiles for each row execute function gac_private.welcome_new_member();
revoke all on function public.gac_owner_message_settings(),public.gac_save_welcome_message(text,boolean),public.gac_message_all_members(text,uuid) from public,anon;
grant execute on function public.gac_owner_message_settings(),public.gac_save_welcome_message(text,boolean),public.gac_message_all_members(text,uuid) to authenticated;
commit;
