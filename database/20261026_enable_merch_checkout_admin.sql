begin;

-- Let the authenticated owner read and toggle the merchandise setting.
-- The Edge Function still independently enforces GAC_LIVE_MERCH_CHECKOUT_ENABLED
-- for all production checkout requests.
create or replace function public.gac_owner_merch_checkout(p_enabled boolean default null)
returns boolean
language plpgsql
security definer
set search_path=''
as $function$
declare current_enabled boolean;
begin
 if auth.uid() is null or not public.gac_is_owner() then
  raise exception 'Owner access required' using errcode='42501';
 end if;

 if p_enabled is null then
  select enabled into current_enabled
  from gac_private.merch_checkout_settings
  where singleton;
  return coalesce(current_enabled,false);
 end if;

 update gac_private.merch_checkout_settings
 set enabled=p_enabled
 where singleton
 returning enabled into current_enabled;

 if not found then
  raise exception 'Merchandise checkout settings are unavailable';
 end if;

 return current_enabled;
end
$function$;

revoke all on function public.gac_owner_merch_checkout(boolean) from public,anon;
grant execute on function public.gac_owner_merch_checkout(boolean) to authenticated;

notify pgrst,'reload schema';
commit;
