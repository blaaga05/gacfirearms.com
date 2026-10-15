begin;
create table gac_private.member_presence (
 user_id uuid not null references public.gac_profiles(user_id) on delete cascade,
 tab_id uuid not null,
 seen_at timestamptz not null default clock_timestamp(),
 primary key(user_id,tab_id)
);
create index member_presence_seen_idx on gac_private.member_presence(seen_at);
alter table gac_private.member_presence enable row level security;
revoke all on gac_private.member_presence from public,anon,authenticated;
create function public.gac_presence_ping(p_tab uuid,p_online boolean default true)
returns void language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid();t timestamptz:=clock_timestamp();
begin
 if u is null or not (public.gac_is_member() or public.gac_is_owner()) then raise exception 'Membership required' using errcode='42501';end if;
 if p_tab is null then raise exception 'Tab identifier required';end if;
 if p_online is distinct from true then delete from gac_private.member_presence where user_id=u and tab_id=p_tab;return;end if;
 if exists(select 1 from gac_private.member_presence where user_id=u and tab_id=p_tab and seen_at>t-interval '15 seconds') then return;end if;
 delete from gac_private.member_presence where seen_at<=t-interval '90 seconds';
 if not exists(select 1 from gac_private.member_presence where user_id=u and tab_id=p_tab) and (select count(*) from gac_private.member_presence where user_id=u)>=20 then
 delete from gac_private.member_presence where user_id=u and tab_id=(select h.tab_id from gac_private.member_presence h where h.user_id=u order by h.seen_at limit 1);
 end if;
 insert into gac_private.member_presence(user_id,tab_id,seen_at) values(u,p_tab,t)
 on conflict(user_id,tab_id) do update set seen_at=excluded.seen_at;
end $$;
create function public.gac_owner_online_members()
returns table(callsign text,is_owner boolean) language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.gac_is_owner() then raise exception 'Owner access required' using errcode='42501';end if;
 return query select p.callsign,exists(select 1 from gac_private.owners o where o.user_id=p.user_id)
 from public.gac_profiles p where p.status='active' and exists(select 1 from gac_private.member_presence h where h.user_id=p.user_id and h.seen_at>clock_timestamp()-interval '90 seconds') order by p.callsign;
end $$;
revoke all on function public.gac_presence_ping(uuid,boolean),public.gac_owner_online_members() from public,anon;
grant execute on function public.gac_presence_ping(uuid,boolean),public.gac_owner_online_members() to authenticated;
commit;
