begin;

create table gac_private.owner_message_push_queue (
 queue_id uuid primary key default gen_random_uuid(),
 message_id uuid not null unique references public.gac_messages(id) on delete cascade,
 member_id uuid not null,
 member_callsign text not null,
 status text not null default 'pending' check(status in('pending','processing','sent','failed')),
 attempt_count integer not null default 0,
 next_attempt_at timestamptz not null default clock_timestamp(),
 locked_until timestamptz,
 sent_at timestamptz,
 last_error text,
 created_at timestamptz not null default clock_timestamp()
);
alter table gac_private.owner_message_push_queue enable row level security;
revoke all on gac_private.owner_message_push_queue from public,anon,authenticated,service_role;

create or replace function gac_private.queue_owner_message_push()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
 if new.sender_kind='member' and new.broadcast_id is null then
  insert into gac_private.owner_message_push_queue(message_id,member_id,member_callsign)
  values(
   new.id,
   new.member_id,
   coalesce((select p.callsign from public.gac_profiles p where p.user_id=new.member_id),'A member')
  )
  on conflict(message_id) do nothing;
 end if;
 return new;
end
$function$;
revoke all on function gac_private.queue_owner_message_push() from public,anon,authenticated,service_role;
create trigger gac_queue_owner_message_push
 after insert on public.gac_messages
 for each row execute function gac_private.queue_owner_message_push();

create or replace function public.gac_claim_owner_message_pushes(p_limit integer default 20)
returns table(queue_id uuid,member_callsign text,owner_ids uuid[])
language plpgsql
security definer
set search_path to ''
as $function$
declare
 v record;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service access required'; end if;

 update gac_private.owner_message_push_queue
 set status='pending',locked_until=null
 where status='processing' and locked_until<=clock_timestamp();

 for v in
  select q.queue_id,q.member_callsign,
   (select coalesce(array_agg(o.user_id),'{}'::uuid[]) from gac_private.owners o) as owner_ids
  from gac_private.owner_message_push_queue q
  join public.gac_messages m on m.id=q.message_id
  where q.status='pending'
   and q.next_attempt_at<=clock_timestamp()
   and q.attempt_count<10
   and m.available_at<=clock_timestamp()
  order by q.created_at
  limit greatest(1,least(coalesce(p_limit,20),50))
  for update of q skip locked
 loop
  update gac_private.owner_message_push_queue
   set status='processing',attempt_count=attempt_count+1,locked_until=clock_timestamp()+interval '5 minutes'
   where gac_private.owner_message_push_queue.queue_id=v.queue_id;
  queue_id:=v.queue_id;
  member_callsign:=v.member_callsign;
  owner_ids:=v.owner_ids;
  return next;
 end loop;
end
$function$;
revoke all on function public.gac_claim_owner_message_pushes(integer) from public,anon,authenticated;
grant execute on function public.gac_claim_owner_message_pushes(integer) to service_role;

create or replace function public.gac_finish_owner_message_push(p_queue_id uuid,p_success boolean,p_error text default null)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare attempts integer;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service access required'; end if;
 select attempt_count into attempts
 from gac_private.owner_message_push_queue
 where queue_id=p_queue_id and status='processing'
 for update;
 if not found then return; end if;
 update gac_private.owner_message_push_queue
 set status=case when p_success then 'sent' when attempts>=10 then 'failed' else 'pending' end,
  sent_at=case when p_success then clock_timestamp() else null end,
  locked_until=null,
  next_attempt_at=case when p_success then next_attempt_at else clock_timestamp()+make_interval(secs=>least(3600,15*(2^least(attempts,8))::integer)) end,
  last_error=case when p_success then null else left(coalesce(p_error,'Owner message push failed.'),500) end
 where queue_id=p_queue_id;
end
$function$;
revoke all on function public.gac_finish_owner_message_push(uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.gac_finish_owner_message_push(uuid,boolean,text) to service_role;

commit;
