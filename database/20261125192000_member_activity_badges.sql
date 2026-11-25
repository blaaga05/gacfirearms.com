begin;
create table gac_private.member_badge_settings (
 singleton boolean primary key default true check(singleton),
 tracking_started_at timestamptz not null default clock_timestamp()
);
alter table gac_private.member_badge_settings enable row level security;
revoke all on gac_private.member_badge_settings from public,anon,authenticated;
insert into gac_private.member_badge_settings(singleton) values(true) on conflict(singleton) do nothing;

drop function if exists public.gac_online_members();
create function public.gac_online_members()
returns table(callsign text,is_owner boolean,badge_key text,badge_label text)
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not (public.gac_is_member() or public.gac_is_owner()) then
  raise exception 'Membership required' using errcode='42501';
 end if;
 return query
 with settings as (
  select tracking_started_at from gac_private.member_badge_settings where singleton
 ),
 online_members as (
  select p.user_id,p.callsign,p.created_at,
         exists(select 1 from gac_private.owners o where o.user_id=p.user_id) as is_owner
  from public.gac_profiles p
  where p.status='active'
    and exists(select 1 from gac_private.member_presence h
               where h.user_id=p.user_id and h.seen_at>clock_timestamp()-interval '90 seconds')
 ),
 participation as (
  select o.user_id,count(distinct c.id)::integer as groups_joined
  from online_members o
  join public.gac_numbers n on n.user_id=o.user_id
  join public.gac_collections c on c.id=n.collection_id
  where not c.is_test and c.state in ('open','closed','recognized')
  group by o.user_id
 ),
 completed_regular_groups as (
  select o.user_id,c.id,c.created_at,
         exists(select 1 from public.gac_numbers n
                where n.user_id=o.user_id and n.collection_id=c.id) as participated
  from online_members o
  cross join settings s
  join public.gac_collections c
    on c.created_at>=greatest(s.tracking_started_at,o.created_at)
  where not c.is_test
    and c.state in ('closed','recognized')
    and c.callsign !~* '(^|[^[:alnum:]])mini([^[:alnum:]]|$)'
 ),
 ordered_regular_groups as (
  select g.*,
         sum(case when g.participated then 1 else 0 end)
           over(partition by g.user_id order by g.created_at desc,g.id desc
                rows between unbounded preceding and current row) as played_seen
  from completed_regular_groups g
 ),
 missed_streaks as (
  select user_id,
         count(*) filter(where not participated and played_seen=0)::integer as missed_regular_groups
  from ordered_regular_groups
  group by user_id
 ),
 badge_levels as (
  select o.user_id,o.callsign,o.is_owner,
         coalesce(p.groups_joined,0) as groups_joined,
         coalesce(m.missed_regular_groups,0) as missed_regular_groups,
         case
          when coalesce(p.groups_joined,0) between 1 and 5 then 1
          when coalesce(p.groups_joined,0) between 6 and 9 then 2
          when coalesce(p.groups_joined,0) between 10 and 24 then 3
          when coalesce(p.groups_joined,0) between 25 and 49 then 4
          when coalesce(p.groups_joined,0)>=50 then 5
          else 0
         end - (coalesce(m.missed_regular_groups,0)/5) as current_level
  from online_members o
  left join participation p on p.user_id=o.user_id
  left join missed_streaks m on m.user_id=o.user_id
 )
 select b.callsign,b.is_owner,
        case
         when b.current_level=1 and b.groups_joined between 1 and 5 and b.missed_regular_groups<5 then 'first_mission'
         when b.current_level=2 then 'regular'
         when b.current_level=3 then 'dedicated'
         when b.current_level=4 then 'veteran'
         when b.current_level>=5 then 'gac_legend'
         else null
        end,
        case
         when b.current_level=1 and b.groups_joined between 1 and 5 and b.missed_regular_groups<5 then 'First Mission'
         when b.current_level=2 then 'Regular'
         when b.current_level=3 then 'Dedicated'
         when b.current_level=4 then 'Veteran'
         when b.current_level>=5 then 'GAC Legend'
         else null
        end
 from badge_levels b
 order by b.callsign;
end
$$;
revoke all on function public.gac_online_members() from public,anon;
grant execute on function public.gac_online_members() to authenticated;
notify pgrst,'reload schema';
commit;
