alter table gac_private.push_notification_settings
  add column if not exists templates jsonb not null default
  '{
    "collection_full":{"title":"Collection full — check payments","message":"{callsign} is full ({assigned}/{quantity}). Review payments before the wheel."},
    "owner_message":{"title":"New GAC member message","message":"{callsign} sent you a private message. Open GAC Messages to reply."},
    "member_recognition":{"title":"You were recognized!","message":"Your number #{number} in {group} has been selected! Check your messages at GAC."},
    "owner_order_member_purchase":{"title":"New callsign purchase","message":"A member bought numbers in {itemLabel}. Open GAC to review."},
    "owner_order_merch_order":{"title":"New merchandise order","message":"{orderLabel} is paid and awaiting fulfillment."},
    "owner_order_firearm_request":{"title":"New firearm order request","message":"{itemLabel} request submitted. Open GAC to review."},
    "owner_order_firearm_checkout":{"title":"Firearm order ready for review","message":"{itemLabel} was authorized and is ready for review."}
  }'::jsonb;

create or replace function public.gac_owner_notification_settings()
returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
begin
  if auth.uid() is null or not public.gac_is_owner() then
    raise exception 'Owner access required' using errcode='42501';
  end if;
  return (
    select jsonb_build_object('enabled', enabled, 'templates', templates, 'updated_at', updated_at)
    from gac_private.push_notification_settings where singleton
  );
end
$function$;

create or replace function public.gac_owner_set_notification_template(p_type text, p_title text, p_message text)
returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  required_tokens text[];
  token text;
  result jsonb;
begin
  if auth.uid() is null or not public.gac_is_owner() then
    raise exception 'Owner access required' using errcode='42501';
  end if;
  if p_type is null or p_title is null or p_message is null then
    raise exception 'Enter a title and message';
  end if;
  if length(trim(p_title)) not between 1 and 80 or length(trim(p_message)) not between 1 and 240 then
    raise exception 'Titles can be 1–80 characters and messages 1–240 characters';
  end if;
  required_tokens := case p_type
    when 'collection_full' then array['{callsign}','{assigned}','{quantity}']
    when 'owner_message' then array['{callsign}']
    when 'member_recognition' then array['{number}','{group}']
    when 'owner_order_member_purchase' then array['{itemLabel}']
    when 'owner_order_merch_order' then array['{orderLabel}']
    when 'owner_order_firearm_request' then array['{itemLabel}']
    when 'owner_order_firearm_checkout' then array['{itemLabel}']
    else null
  end;
  if required_tokens is null then raise exception 'This notification does not have an editable template'; end if;
  foreach token in array required_tokens loop
    if strpos(p_message, token) = 0 then
      raise exception 'Keep the required placeholder % in the message', token;
    end if;
  end loop;
  update gac_private.push_notification_settings
  set templates=jsonb_set(templates,array[p_type],
        jsonb_build_object('title',trim(p_title),'message',trim(p_message)),true),
      updated_at=clock_timestamp(),updated_by=auth.uid()
  where singleton returning templates into result;
  return result;
end
$function$;

create or replace function public.gac_push_notification_template(p_type text)
returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare result jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service access required' using errcode='42501';
  end if;
  if p_type is null or p_type not in (
    'collection_full','owner_message','member_recognition',
    'owner_order_member_purchase','owner_order_merch_order',
    'owner_order_firearm_request','owner_order_firearm_checkout'
  ) then
    raise exception 'Unknown notification template';
  end if;
  select templates -> p_type into result
  from gac_private.push_notification_settings where singleton;
  return coalesce(result,'{}'::jsonb);
end
$function$;

revoke all on function public.gac_owner_notification_settings() from public, anon;
grant execute on function public.gac_owner_notification_settings() to authenticated;
revoke all on function public.gac_owner_set_notification_template(text,text,text) from public, anon;
grant execute on function public.gac_owner_set_notification_template(text,text,text) to authenticated;
revoke all on function public.gac_push_notification_template(text) from public, anon, authenticated;
grant execute on function public.gac_push_notification_template(text) to service_role;
