begin;

create table gac_private.collection_full_push_queue (
 id uuid primary key default gen_random_uuid(),
 collection_id uuid not null references public.gac_collections(id) on delete cascade,
 target_quantity integer not null check(target_quantity>0),
 status text not null default 'pending' check(status in('pending','processing','sent','skipped','failed')),
 attempt_count integer not null default 0,
 next_attempt_at timestamptz not null default clock_timestamp(),
 locked_until timestamptz,
 sent_at timestamptz,
 last_error text,
 created_at timestamptz not null default clock_timestamp(),
 unique(collection_id,target_quantity)
);
alter table gac_private.collection_full_push_queue enable row level security;
revoke all on gac_private.collection_full_push_queue from public,anon,authenticated,service_role;

do $$
begin
 if not exists(select 1 from vault.decrypted_secrets where name='gac_collection_full_push_token') then
  perform vault.create_secret(encode(extensions.gen_random_bytes(32),'hex'),'gac_collection_full_push_token','Authenticates the scheduled full-collection owner push worker');
 end if;
end
$$;

create or replace function gac_private.queue_full_collection_push(p_collection_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
begin
 perform 1 from public.gac_collections where id=p_collection_id for update;
 insert into gac_private.collection_full_push_queue(collection_id,target_quantity)
 select c.id,c.quantity
 from public.gac_collections c
 where c.id=p_collection_id
  and c.is_test is not true
  and c.archived_at is null
  and c.quantity>0
  and (select count(*) from public.gac_numbers n where n.collection_id=c.id)>=c.quantity
 on conflict(collection_id,target_quantity) do nothing;
end
$function$;
revoke all on function gac_private.queue_full_collection_push(uuid) from public,anon,authenticated,service_role;

create or replace function gac_private.queue_full_collection_push_after_number()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
 perform gac_private.queue_full_collection_push(new.collection_id);
 return new;
end
$function$;
revoke all on function gac_private.queue_full_collection_push_after_number() from public,anon,authenticated,service_role;
create trigger gac_queue_full_collection_push_after_number
 after insert on public.gac_numbers
 for each row execute function gac_private.queue_full_collection_push_after_number();

create or replace function gac_private.queue_full_collection_push_after_collection_change()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
 perform gac_private.queue_full_collection_push(new.id);
 return new;
end
$function$;
revoke all on function gac_private.queue_full_collection_push_after_collection_change() from public,anon,authenticated,service_role;
create trigger gac_queue_full_collection_push_after_collection_change
 after update of quantity,is_test,archived_at on public.gac_collections
 for each row execute function gac_private.queue_full_collection_push_after_collection_change();

create or replace function public.gac_verify_collection_full_push_token(p_token text)
returns boolean
language plpgsql
security definer
set search_path to ''
as $function$
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service access required'; end if;
 if p_token is null or p_token !~ '^[a-f0-9]{64}$' then return false; end if;
 return exists(
  select 1 from vault.decrypted_secrets
  where name='gac_collection_full_push_token'
   and extensions.digest(decrypted_secret,'sha256')=extensions.digest(p_token,'sha256')
 );
end
$function$;
revoke all on function public.gac_verify_collection_full_push_token(text) from public,anon,authenticated;
grant execute on function public.gac_verify_collection_full_push_token(text) to service_role;

create or replace function public.gac_claim_collection_full_push_alerts(p_limit integer default 20)
returns table(queue_id uuid,collection_id uuid,callsign text,assigned integer,quantity integer,owner_ids uuid[])
language plpgsql
security definer
set search_path to ''
as $function$
declare
 v record;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service access required'; end if;

 update gac_private.collection_full_push_queue
 set status='pending',locked_until=null
 where status='processing' and locked_until<=clock_timestamp();

 update gac_private.collection_full_push_queue q
 set status='skipped',locked_until=null,last_error='Collection is no longer full or eligible.'
 from public.gac_collections c
 where c.id=q.collection_id
  and q.status='pending'
  and (
   c.is_test is true
   or c.archived_at is not null
   or c.quantity<>q.target_quantity
   or (select count(*) from public.gac_numbers n where n.collection_id=c.id)<q.target_quantity
  );

 for v in
  select q.id as id,c.id as collection_id,c.callsign,
   (select count(*)::integer from public.gac_numbers n where n.collection_id=c.id) as assigned,
   c.quantity,
   (select coalesce(array_agg(o.user_id),'{}'::uuid[]) from gac_private.owners o) as owner_ids
  from gac_private.collection_full_push_queue q
  join public.gac_collections c on c.id=q.collection_id
  where q.status='pending'
   and q.next_attempt_at<=clock_timestamp()
   and q.attempt_count<10
   and c.is_test is not true
   and c.archived_at is null
   and c.quantity=q.target_quantity
   and (select count(*) from public.gac_numbers n where n.collection_id=c.id)>=q.target_quantity
  order by q.created_at
  limit greatest(1,least(coalesce(p_limit,20),50))
  for update of q skip locked
 loop
  update gac_private.collection_full_push_queue
   set status='processing',attempt_count=attempt_count+1,locked_until=clock_timestamp()+interval '5 minutes'
   where id=v.id;
  queue_id:=v.id;
  collection_id:=v.collection_id;
  callsign:=v.callsign;
  assigned:=v.assigned;
  quantity:=v.quantity;
  owner_ids:=v.owner_ids;
  return next;
 end loop;
end
$function$;
revoke all on function public.gac_claim_collection_full_push_alerts(integer) from public,anon,authenticated;
grant execute on function public.gac_claim_collection_full_push_alerts(integer) to service_role;

create or replace function public.gac_finish_collection_full_push_alert(p_queue_id uuid,p_success boolean,p_error text default null)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare attempts integer;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service access required'; end if;
 select attempt_count into attempts
 from gac_private.collection_full_push_queue
 where id=p_queue_id and status='processing'
 for update;
 if not found then return; end if;
 update gac_private.collection_full_push_queue
 set status=case when p_success then 'sent' when attempts>=10 then 'failed' else 'pending' end,
  sent_at=case when p_success then clock_timestamp() else null end,
  locked_until=null,
  next_attempt_at=case when p_success then next_attempt_at else clock_timestamp()+make_interval(secs=>least(3600,15*(2^least(attempts,8))::integer)) end,
  last_error=case when p_success then null else left(coalesce(p_error,'Push delivery failed.'),500) end
 where id=p_queue_id;
end
$function$;
revoke all on function public.gac_finish_collection_full_push_alert(uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.gac_finish_collection_full_push_alert(uuid,boolean,text) to service_role;

create or replace function gac_private.invoke_collection_full_push_alert()
returns bigint
language plpgsql
security definer
set search_path to ''
as $function$
declare token text;request_id bigint;
begin
 select decrypted_secret into strict token from vault.decrypted_secrets where name='gac_collection_full_push_token';
 select net.http_post(
  url:='https://yuuagwxqhxiiybwjhome.supabase.co/functions/v1/gac-collection-full-alert',
  headers:=jsonb_build_object('Content-Type','application/json','x-gac-collection-full-token',token),
  body:='{}'::jsonb,
  timeout_milliseconds:=10000
 ) into request_id;
 return request_id;
end
$function$;
revoke all on function gac_private.invoke_collection_full_push_alert() from public,anon,authenticated;
select cron.schedule('gac-collection-full-push','30 seconds','select gac_private.invoke_collection_full_push_alert()');

commit;