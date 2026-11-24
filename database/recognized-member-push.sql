begin;

create table gac_private.recognition_push_queue (
 queue_id uuid primary key default gen_random_uuid(),
 collection_id uuid not null,
 spin_number integer not null,
 member_id uuid not null,
 member_callsign text not null,
 group_callsign text not null,
 edition_number integer not null,
 reveal_at timestamptz not null,
 status text not null default 'pending' check(status in('pending','processing','sent','failed')),
 attempt_count integer not null default 0,
 next_attempt_at timestamptz not null default clock_timestamp(),
 locked_until timestamptz,
 sent_at timestamptz,
 last_error text,
 created_at timestamptz not null default clock_timestamp(),
 unique(collection_id,spin_number),
 foreign key(collection_id,spin_number) references public.gac_recognition_awards(collection_id,spin_number) on delete cascade
);
alter table gac_private.recognition_push_queue enable row level security;
revoke all on gac_private.recognition_push_queue from public,anon,authenticated,service_role;

create or replace function gac_private.queue_recognition_member_push()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
 if new.is_test is not true then
  insert into gac_private.recognition_push_queue(collection_id,spin_number,member_id,member_callsign,group_callsign,edition_number,reveal_at)
  values(new.collection_id,new.spin_number,new.user_id,new.member_callsign,new.group_callsign,new.edition_number,new.reveal_at)
  on conflict(collection_id,spin_number) do nothing;
 end if;
 return new;
end
$function$;
revoke all on function gac_private.queue_recognition_member_push() from public,anon,authenticated,service_role;
create trigger gac_queue_recognition_member_push
 after insert on public.gac_recognition_awards
 for each row execute function gac_private.queue_recognition_member_push();

create or replace function public.gac_claim_recognition_member_pushes(p_limit integer default 20)
returns table(queue_id uuid,member_id uuid,member_callsign text,group_callsign text,edition_number integer,spin_number integer)
language plpgsql
security definer
set search_path to ''
as $function$
declare
 v record;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service access required'; end if;

 update gac_private.recognition_push_queue
 set status='pending',locked_until=null
 where status='processing' and locked_until<=clock_timestamp();

 for v in
  select q.queue_id,q.member_id,q.member_callsign,q.group_callsign,q.edition_number,q.spin_number
  from gac_private.recognition_push_queue q
  where q.status='pending'
   and q.reveal_at<=clock_timestamp()
   and q.next_attempt_at<=clock_timestamp()
   and q.attempt_count<10
  order by q.reveal_at,q.created_at
  limit greatest(1,least(coalesce(p_limit,20),50))
  for update of q skip locked
 loop
  update gac_private.recognition_push_queue
   set status='processing',attempt_count=attempt_count+1,locked_until=clock_timestamp()+interval '5 minutes'
   where gac_private.recognition_push_queue.queue_id=v.queue_id;
  queue_id:=v.queue_id;
  member_id:=v.member_id;
  member_callsign:=v.member_callsign;
  group_callsign:=v.group_callsign;
  edition_number:=v.edition_number;
  spin_number:=v.spin_number;
  return next;
 end loop;
end
$function$;
revoke all on function public.gac_claim_recognition_member_pushes(integer) from public,anon,authenticated;
grant execute on function public.gac_claim_recognition_member_pushes(integer) to service_role;

create or replace function public.gac_finish_recognition_member_push(p_queue_id uuid,p_success boolean,p_error text default null)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare attempts integer;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service access required'; end if;
 select attempt_count into attempts
 from gac_private.recognition_push_queue
 where queue_id=p_queue_id and status='processing'
 for update;
 if not found then return; end if;
 update gac_private.recognition_push_queue
 set status=case when p_success then 'sent' when attempts>=10 then 'failed' else 'pending' end,
  sent_at=case when p_success then clock_timestamp() else null end,
  locked_until=null,
  next_attempt_at=case when p_success then next_attempt_at else clock_timestamp()+make_interval(secs=>least(3600,15*(2^least(attempts,8))::integer)) end,
  last_error=case when p_success then null else left(coalesce(p_error,'Push delivery failed.'),500) end
 where queue_id=p_queue_id;
end
$function$;
revoke all on function public.gac_finish_recognition_member_push(uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.gac_finish_recognition_member_push(uuid,boolean,text) to service_role;

commit;
