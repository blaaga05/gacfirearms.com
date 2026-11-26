begin;

alter table public.gac_profiles
  add column if not exists recognition_reminders_enabled boolean not null default true;

create table if not exists gac_private.recognition_reminder_push_queue (
  queue_id uuid primary key default gen_random_uuid(),
  collection_id uuid not null references public.gac_collections(id) on delete cascade,
  member_id uuid not null references public.gac_profiles(user_id) on delete cascade,
  recognition_at timestamptz not null,
  reminder_at timestamptz not null,
  status text not null default 'pending'
    check(status in('pending','processing','sent','failed','cancelled')),
  attempt_count integer not null default 0,
  next_attempt_at timestamptz not null default clock_timestamp(),
  locked_until timestamptz,
  sent_at timestamptz,
  last_error text,
  created_at timestamptz not null default clock_timestamp(),
  unique(collection_id,member_id,recognition_at)
);
alter table gac_private.recognition_reminder_push_queue enable row level security;
revoke all on gac_private.recognition_reminder_push_queue from public,anon,authenticated,service_role;

update gac_private.push_notification_settings
set enabled=jsonb_set(
      enabled,
      '{recognition_reminder}',
      coalesce(enabled->'recognition_reminder','true'::jsonb),
      true
    ),
    templates=jsonb_set(
      templates,
      '{recognition_reminder}',
      coalesce(templates->'recognition_reminder',
        '{"title":"Recognition starts in 10 minutes","message":"{group} recognition begins in 10 minutes."}'::jsonb),
      true
    ),
    updated_at=clock_timestamp()
where singleton;

create or replace function public.gac_owner_set_notification_enabled(p_type text,p_enabled boolean)
returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare result jsonb;
begin
  if auth.uid() is null or not public.gac_is_owner() then
    raise exception 'Owner access required' using errcode='42501';
  end if;
  if p_type is null or p_type not in
    ('collection_full','owner_message','owner_order','member_recognition','recognition_reminder','all_members','member_direct')
    or p_enabled is null then
    raise exception 'Choose a valid notification type and setting';
  end if;
  update gac_private.push_notification_settings
  set enabled=jsonb_set(enabled,array[p_type],to_jsonb(p_enabled),true),
      updated_at=clock_timestamp(),updated_by=auth.uid()
  where singleton returning enabled into result;
  return result;
end
$function$;

create or replace function public.gac_push_notification_enabled(p_type text)
returns boolean language plpgsql stable security definer set search_path to ''
as $function$
declare result boolean;
begin
  if (select auth.jwt()->>'role') is distinct from 'service_role' then
    raise exception 'Service access required' using errcode='42501';
  end if;
  if p_type is null or p_type not in
    ('collection_full','owner_message','owner_order','member_recognition','recognition_reminder','all_members','member_direct') then
    raise exception 'Unknown notification type';
  end if;
  select coalesce((enabled->>p_type)::boolean,true) into result
  from gac_private.push_notification_settings where singleton;
  return coalesce(result,true);
end
$function$;

create or replace function public.gac_owner_set_notification_template(p_type text,p_title text,p_message text)
returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare required_tokens text[]; token text; result jsonb;
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
  required_tokens:=case p_type
    when 'collection_full' then array['{callsign}','{assigned}','{quantity}']
    when 'owner_message' then array['{callsign}']
    when 'member_recognition' then array['{number}','{group}']
    when 'recognition_reminder' then array['{group}']
    when 'owner_order_member_purchase' then array['{itemLabel}']
    when 'owner_order_merch_order' then array['{orderLabel}']
    when 'owner_order_firearm_request' then array['{itemLabel}']
    when 'owner_order_firearm_checkout' then array['{itemLabel}']
    else null
  end;
  if required_tokens is null then raise exception 'This notification does not have an editable template'; end if;
  foreach token in array required_tokens loop
    if strpos(p_message,token)=0 then
      raise exception 'Keep the required placeholder % in the message',token;
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
  if (select auth.jwt()->>'role') is distinct from 'service_role' then
    raise exception 'Service access required' using errcode='42501';
  end if;
  if p_type is null or p_type not in (
    'collection_full','owner_message','member_recognition','recognition_reminder',
    'owner_order_member_purchase','owner_order_merch_order',
    'owner_order_firearm_request','owner_order_firearm_checkout'
  ) then
    raise exception 'Unknown notification template';
  end if;
  select templates->p_type into result
  from gac_private.push_notification_settings where singleton;
  return coalesce(result,'{}'::jsonb);
end
$function$;

revoke all on function public.gac_owner_set_notification_enabled(text,boolean) from public,anon;
grant execute on function public.gac_owner_set_notification_enabled(text,boolean) to authenticated;
revoke all on function public.gac_push_notification_enabled(text) from public,anon,authenticated;
grant execute on function public.gac_push_notification_enabled(text) to service_role;
revoke all on function public.gac_owner_set_notification_template(text,text,text) from public,anon;
grant execute on function public.gac_owner_set_notification_template(text,text,text) to authenticated;
revoke all on function public.gac_push_notification_template(text) from public,anon,authenticated;
grant execute on function public.gac_push_notification_template(text) to service_role;

create or replace function gac_private.queue_recognition_reminders(p_collection_id uuid)
returns void language plpgsql security definer set search_path to ''
as $function$
begin
  update gac_private.recognition_reminder_push_queue q
  set status='cancelled',locked_until=null,last_error='Recognition schedule or member preference changed.'
  where q.collection_id=p_collection_id
    and q.status='pending'
    and not exists (
      select 1
      from public.gac_collections c
      join public.gac_numbers n on n.collection_id=c.id and n.user_id=q.member_id
      join public.gac_profiles p on p.user_id=n.user_id
      where c.id=p_collection_id
        and c.recognition_at=q.recognition_at
        and c.recognition_at>clock_timestamp()
        and c.is_test is not true
        and c.archived_at is null
        and p.status='active'
        and p.recognition_reminders_enabled is true
    );

  insert into gac_private.recognition_reminder_push_queue(
    collection_id,member_id,recognition_at,reminder_at
  )
  select distinct c.id,p.user_id,c.recognition_at,c.recognition_at-interval '10 minutes'
  from public.gac_collections c
  join public.gac_numbers n on n.collection_id=c.id
  join public.gac_profiles p on p.user_id=n.user_id
  where c.id=p_collection_id
    and c.recognition_at>=clock_timestamp()+interval '10 minutes'
    and c.is_test is not true
    and c.archived_at is null
    and p.status='active'
    and p.recognition_reminders_enabled is true
  on conflict(collection_id,member_id,recognition_at) do nothing;
end
$function$;
revoke all on function gac_private.queue_recognition_reminders(uuid) from public,anon,authenticated,service_role;

create or replace function gac_private.queue_recognition_reminders_after_collection()
returns trigger language plpgsql security definer set search_path to ''
as $function$
begin
  perform gac_private.queue_recognition_reminders(new.id);
  return new;
end
$function$;
revoke all on function gac_private.queue_recognition_reminders_after_collection() from public,anon,authenticated,service_role;
drop trigger if exists gac_queue_recognition_reminders_after_collection on public.gac_collections;
create trigger gac_queue_recognition_reminders_after_collection
after insert or update of recognition_at,is_test,archived_at on public.gac_collections
for each row execute function gac_private.queue_recognition_reminders_after_collection();

create or replace function gac_private.queue_recognition_reminders_after_number()
returns trigger language plpgsql security definer set search_path to ''
as $function$
begin
  perform gac_private.queue_recognition_reminders(new.collection_id);
  return new;
end
$function$;
revoke all on function gac_private.queue_recognition_reminders_after_number() from public,anon,authenticated,service_role;
drop trigger if exists gac_queue_recognition_reminders_after_number on public.gac_numbers;
create trigger gac_queue_recognition_reminders_after_number
after insert on public.gac_numbers
for each row execute function gac_private.queue_recognition_reminders_after_number();

create or replace function gac_private.queue_recognition_reminders_after_profile()
returns trigger language plpgsql security definer set search_path to ''
as $function$
declare r record;
begin
  if new.recognition_reminders_enabled is true and new.status='active' then
    for r in
      select distinct n.collection_id
      from public.gac_numbers n
      where n.user_id=new.user_id
    loop
      perform gac_private.queue_recognition_reminders(r.collection_id);
    end loop;
  else
    update gac_private.recognition_reminder_push_queue
    set status='cancelled',locked_until=null,last_error='Member disabled recognition reminders or became inactive.'
    where member_id=new.user_id and status='pending';
  end if;
  return new;
end
$function$;
revoke all on function gac_private.queue_recognition_reminders_after_profile() from public,anon,authenticated,service_role;
drop trigger if exists gac_queue_recognition_reminders_after_profile on public.gac_profiles;
create trigger gac_queue_recognition_reminders_after_profile
after update of recognition_reminders_enabled,status on public.gac_profiles
for each row
when (old.recognition_reminders_enabled is distinct from new.recognition_reminders_enabled or old.status is distinct from new.status)
execute function gac_private.queue_recognition_reminders_after_profile();

create or replace function public.gac_claim_recognition_reminder_pushes(p_limit integer default 20)
returns table(queue_id uuid,member_id uuid,group_callsign text)
language plpgsql security definer set search_path to ''
as $function$
declare v record;
begin
  if (select auth.jwt()->>'role') is distinct from 'service_role' then
    raise exception 'Service access required' using errcode='42501';
  end if;

  update gac_private.recognition_reminder_push_queue
  set status='pending',locked_until=null
  where status='processing' and locked_until<=clock_timestamp();

  for v in
    select q.queue_id,q.member_id,c.callsign
    from gac_private.recognition_reminder_push_queue q
    join public.gac_collections c on c.id=q.collection_id and c.recognition_at=q.recognition_at
    join public.gac_profiles p on p.user_id=q.member_id
    where q.status='pending'
      and q.reminder_at<=clock_timestamp()
      and q.recognition_at>clock_timestamp()
      and q.next_attempt_at<=clock_timestamp()
      and q.attempt_count<10
      and c.is_test is not true
      and c.archived_at is null
      and p.status='active'
      and p.recognition_reminders_enabled is true
    order by q.reminder_at,q.created_at
    limit greatest(1,least(coalesce(p_limit,20),50))
    for update of q skip locked
  loop
    update gac_private.recognition_reminder_push_queue
    set status='processing',attempt_count=attempt_count+1,locked_until=clock_timestamp()+interval '5 minutes'
    where gac_private.recognition_reminder_push_queue.queue_id=v.queue_id;
    queue_id:=v.queue_id;
    member_id:=v.member_id;
    group_callsign:=v.callsign;
    return next;
  end loop;
end
$function$;
revoke all on function public.gac_claim_recognition_reminder_pushes(integer) from public,anon,authenticated;
grant execute on function public.gac_claim_recognition_reminder_pushes(integer) to service_role;

create or replace function public.gac_finish_recognition_reminder_push(p_queue_id uuid,p_success boolean,p_error text default null)
returns void language plpgsql security definer set search_path to ''
as $function$
declare attempts integer;
begin
  if (select auth.jwt()->>'role') is distinct from 'service_role' then
    raise exception 'Service access required' using errcode='42501';
  end if;
  select attempt_count into attempts
  from gac_private.recognition_reminder_push_queue
  where queue_id=p_queue_id and status='processing'
  for update;
  if not found then return; end if;
  update gac_private.recognition_reminder_push_queue
  set status=case when p_success then 'sent' when attempts>=10 then 'failed' else 'pending' end,
      sent_at=case when p_success then clock_timestamp() else null end,
      locked_until=null,
      next_attempt_at=case when p_success then next_attempt_at else clock_timestamp()+make_interval(secs=>least(3600,15*(2^least(attempts,8))::integer)) end,
      last_error=case when p_success then null else left(coalesce(p_error,'Recognition reminder push failed.'),500) end
  where queue_id=p_queue_id;
end
$function$;
revoke all on function public.gac_finish_recognition_reminder_push(uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.gac_finish_recognition_reminder_push(uuid,boolean,text) to service_role;

do $backfill$
declare r record;
begin
  for r in select distinct collection_id from public.gac_numbers loop
    perform gac_private.queue_recognition_reminders(r.collection_id);
  end loop;
end
$backfill$;

commit;