create table if not exists gac_private.push_notification_settings (
  singleton boolean primary key default true check (singleton),
  enabled jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default clock_timestamp(),
  updated_by uuid
);
revoke all on gac_private.push_notification_settings from public, anon, authenticated;
insert into gac_private.push_notification_settings(singleton, enabled)
values (true, '{"collection_full":true,"owner_message":true,"owner_order":true,"member_recognition":true,"all_members":true,"member_direct":true}'::jsonb)
on conflict (singleton) do nothing;

create or replace function public.gac_owner_notification_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
  if auth.uid() is null or not public.gac_is_owner() then
    raise exception 'Owner access required' using errcode='42501';
  end if;
  return (
    select jsonb_build_object('enabled', enabled, 'updated_at', updated_at)
    from gac_private.push_notification_settings
    where singleton
  );
end
$function$;

create or replace function public.gac_owner_set_notification_enabled(p_type text, p_enabled boolean)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare result jsonb;
begin
  if auth.uid() is null or not public.gac_is_owner() then
    raise exception 'Owner access required' using errcode='42501';
  end if;
  if p_type is null or p_type not in
    ('collection_full','owner_message','owner_order','member_recognition','all_members','member_direct')
    or p_enabled is null then
    raise exception 'Choose a valid notification type and setting';
  end if;
  update gac_private.push_notification_settings
  set enabled=jsonb_set(enabled, array[p_type], to_jsonb(p_enabled), true),
      updated_at=clock_timestamp(), updated_by=auth.uid()
  where singleton
  returning enabled into result;
  return result;
end
$function$;

create or replace function public.gac_push_notification_enabled(p_type text)
returns boolean
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare result boolean;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service access required' using errcode='42501';
  end if;
  if p_type is null or p_type not in
    ('collection_full','owner_message','owner_order','member_recognition','all_members','member_direct') then
    raise exception 'Unknown notification type';
  end if;
  select coalesce((enabled ->> p_type)::boolean, true)
  into result
  from gac_private.push_notification_settings
  where singleton;
  return coalesce(result, true);
end
$function$;

revoke all on function public.gac_owner_notification_settings() from public, anon;
grant execute on function public.gac_owner_notification_settings() to authenticated;
revoke all on function public.gac_owner_set_notification_enabled(text, boolean) from public, anon;
grant execute on function public.gac_owner_set_notification_enabled(text, boolean) to authenticated;
revoke all on function public.gac_push_notification_enabled(text) from public, anon, authenticated;
grant execute on function public.gac_push_notification_enabled(text) to service_role;
