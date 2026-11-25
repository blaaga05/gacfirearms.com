begin;
create or replace function public.gac_online_members()
returns table(callsign text,is_owner boolean)
language plpgsql
security definer
set search_path=''
as $$
begin
 if auth.uid() is null or not (public.gac_is_member() or public.gac_is_owner()) then
  raise exception 'Membership required' using errcode='42501';
 end if;
 return query
 select p.callsign,
        exists(select 1 from gac_private.owners o where o.user_id=p.user_id)
 from public.gac_profiles p
 where p.status='active'
   and exists(
     select 1 from gac_private.member_presence h
     where h.user_id=p.user_id
       and h.seen_at>clock_timestamp()-interval '90 seconds'
   )
 order by p.callsign;
end
$$;
revoke all on function public.gac_online_members() from public,anon;
grant execute on function public.gac_online_members() to authenticated;
commit;
