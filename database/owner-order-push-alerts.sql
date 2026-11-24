begin;

create table gac_private.owner_order_push_queue (
 queue_id uuid primary key default gen_random_uuid(),
 event_type text not null check(event_type in('member_purchase','merch_order','firearm_request','firearm_checkout')),
 event_id uuid not null,
 item_label text not null,
 order_reference text,
 status text not null default 'pending' check(status in('pending','processing','sent','failed')),
 attempt_count integer not null default 0,
 next_attempt_at timestamptz not null default clock_timestamp(),
 locked_until timestamptz,
 sent_at timestamptz,
 last_error text,
 created_at timestamptz not null default clock_timestamp(),
 unique(event_type,event_id)
);
alter table gac_private.owner_order_push_queue enable row level security;
revoke all on gac_private.owner_order_push_queue from public,anon,authenticated,service_role;

create or replace function gac_private.enqueue_owner_order_push(p_event_type text,p_event_id uuid,p_item_label text,p_order_reference text default null)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
begin
 if p_event_type not in ('member_purchase','merch_order','firearm_request','firearm_checkout') then
  raise exception 'Unsupported owner order alert type';
 end if;
 insert into gac_private.owner_order_push_queue(event_type,event_id,item_label,order_reference)
 values(p_event_type,p_event_id,left(coalesce(nullif(trim(p_item_label),''),'GAC order'),100),left(nullif(trim(p_order_reference),''),80))
 on conflict(event_type,event_id) do nothing;
end
$function$;
revoke all on function gac_private.enqueue_owner_order_push(text,uuid,text,text) from public,anon,authenticated,service_role;

create or replace function gac_private.queue_paid_member_purchase_push()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare v_callsign text;
begin
 if new.is_test is not true and new.payment_status='paid' and new.assignment_kind is null then
  select coalesce(c.callsign,'GAC collection') into v_callsign
  from public.gac_collections c where c.id=new.collection_id;
  perform gac_private.enqueue_owner_order_push('member_purchase',new.id,coalesce(v_callsign,'GAC collection'),null);
 end if;
 return new;
end
$function$;
revoke all on function gac_private.queue_paid_member_purchase_push() from public,anon,authenticated,service_role;
create trigger gac_queue_owner_paid_member_purchase_push
 after insert on public.gac_orders
 for each row execute function gac_private.queue_paid_member_purchase_push();

create or replace function gac_private.queue_paid_merch_order_push()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
 if new.payment_status='paid' then
  perform gac_private.enqueue_owner_order_push('merch_order',new.id,'Merchandise order',new.order_number);
 end if;
 return new;
end
$function$;
revoke all on function gac_private.queue_paid_merch_order_push() from public,anon,authenticated,service_role;
create trigger gac_queue_owner_paid_merch_order_push
 after insert on public.gac_store_orders
 for each row when (new.payment_status='paid')
 execute function gac_private.queue_paid_merch_order_push();

create or replace function gac_private.queue_firearm_order_request_push()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
 if new.review_status='pending_review' then
  perform gac_private.enqueue_owner_order_push('firearm_request',new.id,new.firearm_name,null);
 end if;
 return new;
end
$function$;
revoke all on function gac_private.queue_firearm_order_request_push() from public,anon,authenticated,service_role;
create trigger gac_queue_owner_firearm_order_request_push
 after insert on public.gac_firearm_order_requests
 for each row when (new.review_status='pending_review')
 execute function gac_private.queue_firearm_order_request_push();

create or replace function gac_private.queue_authorized_firearm_order_push()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
 if old.status is distinct from new.status and new.status='authorized_pending_review' then
  perform gac_private.enqueue_owner_order_push('firearm_checkout',new.id,new.firearm_name,new.invoice_number);
 end if;
 return new;
end
$function$;
revoke all on function gac_private.queue_authorized_firearm_order_push() from public,anon,authenticated,service_role;
create trigger gac_queue_owner_authorized_firearm_order_push
 after update of status on public.gac_firearm_checkout_orders
 for each row when (old.status is distinct from new.status and new.status='authorized_pending_review')
 execute function gac_private.queue_authorized_firearm_order_push();

create or replace function public.gac_claim_owner_order_pushes(p_limit integer default 20)
returns table(queue_id uuid,event_type text,item_label text,order_reference text,owner_ids uuid[])
language plpgsql
security definer
set search_path to ''
as $function$
declare
 v record;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service access required'; end if;

 update gac_private.owner_order_push_queue
 set status='pending',locked_until=null
 where status='processing' and locked_until<=clock_timestamp();

 for v in
  select q.queue_id,q.event_type,q.item_label,q.order_reference,
   (select coalesce(array_agg(o.user_id),'{}'::uuid[]) from gac_private.owners o) as owner_ids
  from gac_private.owner_order_push_queue q
  where q.status='pending'
   and q.next_attempt_at<=clock_timestamp()
   and q.attempt_count<10
  order by q.created_at
  limit greatest(1,least(coalesce(p_limit,20),50))
  for update of q skip locked
 loop
  update gac_private.owner_order_push_queue
   set status='processing',attempt_count=attempt_count+1,locked_until=clock_timestamp()+interval '5 minutes'
   where gac_private.owner_order_push_queue.queue_id=v.queue_id;
  queue_id:=v.queue_id;
  event_type:=v.event_type;
  item_label:=v.item_label;
  order_reference:=v.order_reference;
  owner_ids:=v.owner_ids;
  return next;
 end loop;
end
$function$;
revoke all on function public.gac_claim_owner_order_pushes(integer) from public,anon,authenticated;
grant execute on function public.gac_claim_owner_order_pushes(integer) to service_role;

create or replace function public.gac_finish_owner_order_push(p_queue_id uuid,p_success boolean,p_error text default null)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare attempts integer;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service access required'; end if;
 select attempt_count into attempts
 from gac_private.owner_order_push_queue
 where queue_id=p_queue_id and status='processing'
 for update;
 if not found then return; end if;
 update gac_private.owner_order_push_queue
 set status=case when p_success then 'sent' when attempts>=10 then 'failed' else 'pending' end,
  sent_at=case when p_success then clock_timestamp() else null end,
  locked_until=null,
  next_attempt_at=case when p_success then next_attempt_at else clock_timestamp()+make_interval(secs=>least(3600,15*(2^least(attempts,8))::integer)) end,
  last_error=case when p_success then null else left(coalesce(p_error,'Owner order push failed.'),500) end
 where queue_id=p_queue_id;
end
$function$;
revoke all on function public.gac_finish_owner_order_push(uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.gac_finish_owner_order_push(uuid,boolean,text) to service_role;

commit;
