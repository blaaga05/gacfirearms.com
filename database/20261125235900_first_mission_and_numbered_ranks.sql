begin;
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
  select o.user_id,count(distinct c.id)::integer as groups_played
  from online_members o
  join public.gac_numbers n on n.user_id=o.user_id
  join public.gac_collections c on c.id=n.collection_id
  where not c.is_test and c.state in ('closed','recognized')
  group by o.user_id
 ),
 first_played_group as (
  select distinct on (n.user_id) n.user_id,c.state
  from online_members o
  join public.gac_numbers n on n.user_id=o.user_id
  join public.gac_collections c on c.id=n.collection_id
  join public.gac_orders ord on ord.id=n.order_id
  where not c.is_test and c.state in ('open','closed','recognized')
  order by n.user_id,ord.created_at,c.created_at,c.id
 ),
 first_mission_status as (
  select o.user_id,coalesce(f.state in ('open','closed'),false) as available
  from online_members o
  left join first_played_group f on f.user_id=o.user_id
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
         coalesce(p.groups_played,0) as groups_played,
         coalesce(m.missed_regular_groups,0) as missed_regular_groups,
         coalesce(f.available,false) as first_mission_available,
         case
          when coalesce(p.groups_played,0)>=35 and coalesce(m.missed_regular_groups,0)<10 then 4
          when coalesce(p.groups_played,0)>=35 and coalesce(m.missed_regular_groups,0)<20 then 3
          when coalesce(p.groups_played,0)>=35 then greatest(0,2-((coalesce(m.missed_regular_groups,0)-20)/5))
          when coalesce(p.groups_played,0)>=20 and coalesce(m.missed_regular_groups,0)<10 then 3
          when coalesce(p.groups_played,0)>=20 then greatest(0,2-((coalesce(m.missed_regular_groups,0)-10)/5))
          when coalesce(p.groups_played,0)>=10 then greatest(0,2-(coalesce(m.missed_regular_groups,0)/5))
          when coalesce(p.groups_played,0) between 5 and 9 then greatest(0,1-(coalesce(m.missed_regular_groups,0)/5))
          else 0
         end as current_level
  from online_members o
  left join participation p on p.user_id=o.user_id
  left join missed_streaks m on m.user_id=o.user_id
  left join first_mission_status f on f.user_id=o.user_id
 )
 select b.callsign,b.is_owner,
        case
         when b.first_mission_available then 'first_mission'
         when b.current_level=1 then 'regular'
         when b.current_level=2 then 'dedicated'
         when b.current_level=3 then 'veteran'
         when b.current_level>=4 then 'gac_legend'
         else null
        end,
        case
         when b.first_mission_available then 'First Mission'
         when b.current_level=1 then 'Regular'
         when b.current_level=2 then 'Dedicated'
         when b.current_level=3 then 'Veteran'
         when b.current_level>=4 then 'GAC Legend'
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
