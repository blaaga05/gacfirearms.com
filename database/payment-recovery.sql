begin;
create extension if not exists pg_net with schema extensions;
create table gac_private.payment_recovery_state(singleton boolean primary key default true check(singleton),endpoint text not null,lease_id uuid,lease_until timestamptz,cursor jsonb not null default '{"stage":"unsettled","page":1}',scan_from timestamptz not null default now()-interval '7 days',last_started_at timestamptz,last_success_at timestamptz,last_error text);
insert into gac_private.payment_recovery_state(singleton,endpoint) values(true,'__PROJECT_URL__/functions/v1/gac-payment-recovery');
create table gac_private.payment_recovery_queue(transaction_id text primary key check(transaction_id~'^[0-9]{1,30}$'),next_check_at timestamptz not null default now(),attempts integer not null default 0,last_checked_at timestamptz,last_outcome text);
create table gac_private.gateway_transactions(transaction_id text primary key,checkout_id uuid not null references gac_private.authorizenet_checkouts(id),reference_transaction text,kind text not null,status text not null,amount_cents integer not null check(amount_cents>=0),observed_at timestamptz not null default now());
alter table public.gac_orders add column payment_status text not null default 'paid' check(payment_status in('paid','voided','refund_pending','partially_refunded','refunded'));
alter table gac_private.payment_recovery_state enable row level security;
alter table gac_private.payment_recovery_queue enable row level security;
alter table gac_private.gateway_transactions enable row level security;
revoke all on gac_private.payment_recovery_state,gac_private.payment_recovery_queue,gac_private.gateway_transactions from public,anon,authenticated;
do $$begin if not exists(select 1 from vault.secrets where name='gac_payment_recovery_token') then perform vault.create_secret(encode(extensions.gen_random_bytes(32),'hex'),'gac_payment_recovery_token');end if;end $$;
create function public.gac_verify_recovery_token(p_token text) returns boolean language plpgsql security definer set search_path='' as $$
begin
 if (select auth.role()) is distinct from 'service_role' then raise exception 'Service access required';end if;
 if p_token is null or p_token!~'^[a-f0-9]{64}$' then return false;end if;
 return exists(select 1 from vault.decrypted_secrets where name='gac_payment_recovery_token' and extensions.digest(decrypted_secret,'sha256')=extensions.digest(p_token,'sha256'));
end $$;
create function public.gac_claim_payment_recovery() returns jsonb language plpgsql security definer set search_path='' as $$
declare s gac_private.payment_recovery_state;l uuid:=extensions.gen_random_uuid();
begin
 if (select auth.role()) is distinct from 'service_role' then raise exception 'Service access required';end if;
 select * into strict s from gac_private.payment_recovery_state where singleton for update;
 if s.lease_until>clock_timestamp() then return null;end if;
 update gac_private.payment_recovery_state set lease_id=l,lease_until=clock_timestamp()+interval '2 minutes',last_started_at=clock_timestamp() where singleton;
 return jsonb_build_object('lease',l,'cursor',s.cursor,'scan_from',s.scan_from);
end $$;
create function public.gac_checkpoint_payment_recovery(p_lease uuid,p_cursor jsonb,p_scan_from timestamptz,p_finished boolean default false,p_error boolean default false) returns void language plpgsql security definer set search_path='' as $$
begin
 if (select auth.role()) is distinct from 'service_role' then raise exception 'Service access required';end if;
 update gac_private.payment_recovery_state set cursor=p_cursor,scan_from=p_scan_from,last_success_at=case when p_finished and not p_error then clock_timestamp() else last_success_at end,last_error=case when p_error then 'Recovery incomplete; scheduled retry required' else null end,lease_until=case when p_finished then null else lease_until end,lease_id=case when p_finished then null else lease_id end where singleton and lease_id=p_lease and lease_until>clock_timestamp();
 if not found then raise exception 'Recovery lease expired';end if;
end $$;
create function public.gac_enqueue_payment_recovery(p_candidates jsonb) returns integer language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 if (select auth.role()) is distinct from 'service_role' then raise exception 'Service access required';end if;
 if jsonb_typeof(p_candidates)<>'array' or jsonb_array_length(p_candidates)>1000 then raise exception 'Invalid recovery page';end if;
 insert into gac_private.payment_recovery_queue(transaction_id)
 select distinct x->>'id' from jsonb_array_elements(p_candidates)x where x->>'id'~'^[0-9]{1,30}$' and (exists(select 1 from gac_private.authorizenet_checkouts i where i.invoice=x->>'invoice') or exists(select 1 from gac_private.payment_recovery_queue q where q.transaction_id=x->>'id') or x->>'status' in('refundPendingSettlement','refundSettledSuccessfully')) on conflict(transaction_id) do nothing;
 get diagnostics n=row_count;return n;
end $$;
create function public.gac_due_payment_recovery() returns table(transaction_id text) language plpgsql security definer set search_path='' as $$
begin
 if (select auth.role()) is distinct from 'service_role' then raise exception 'Service access required';end if;
 return query select q.transaction_id from gac_private.payment_recovery_queue q where q.next_check_at<=clock_timestamp() order by q.next_check_at,q.transaction_id limit 20;
end $$;
create function public.gac_finish_payment_recovery(p_transaction text,p_ok boolean,p_terminal boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 if (select auth.role()) is distinct from 'service_role' then raise exception 'Service access required';end if;
 update gac_private.payment_recovery_queue set attempts=attempts+1,last_checked_at=clock_timestamp(),last_outcome=case when p_ok then 'checked' else 'retry' end,next_check_at=clock_timestamp()+case when not p_ok then interval '5 minutes' when p_terminal then interval '1 day' else interval '5 minutes' end where transaction_id=p_transaction;
end $$;
create function public.gac_observe_gateway_transaction(p_transaction text,p_invoice text,p_reference text,p_kind text,p_status text,p_amount_cents integer) returns text language plpgsql security definer set search_path='' as $$
declare i gac_private.authorizenet_checkouts;paid_refunds bigint;pending_refunds bigint;state text;
begin
 if (select auth.role()) is distinct from 'service_role' then raise exception 'Service access required';end if;
 if p_transaction!~'^[0-9]{1,30}$' or p_amount_cents is null or p_amount_cents<0 or length(p_status)>100 or length(p_kind)>100 then raise exception 'Invalid gateway observation';end if;
 select * into i from gac_private.authorizenet_checkouts where invoice=p_invoice or transaction_id=p_transaction or transaction_id=p_reference or id in(select checkout_id from gac_private.authorizenet_payment_reviews where transaction_id in(p_transaction,p_reference)) order by created_at limit 1;
 if not found then return 'unrelated';end if;
 perform 1 from public.gac_collections where id=i.collection_id for update;
 insert into gac_private.gateway_transactions(transaction_id,checkout_id,reference_transaction,kind,status,amount_cents) values(p_transaction,i.id,p_reference,p_kind,p_status,p_amount_cents) on conflict(transaction_id) do update set status=excluded.status,amount_cents=excluded.amount_cents,observed_at=clock_timestamp() where gac_private.gateway_transactions.checkout_id=excluded.checkout_id and gac_private.gateway_transactions.kind=excluded.kind;
 if not found then raise exception 'Gateway transaction association conflict';end if;
 if i.order_id is not null then
 select coalesce(sum(amount_cents) filter(where status='refundSettledSuccessfully'),0),coalesce(sum(amount_cents) filter(where status='refundPendingSettlement'),0) into paid_refunds,pending_refunds from gac_private.gateway_transactions where checkout_id=i.id and kind='refundTransaction';
 if exists(select 1 from gac_private.gateway_transactions where checkout_id=i.id and transaction_id=i.transaction_id and status='voided') then state:='voided';
 elsif paid_refunds>=i.amount_cents then state:='refunded';elsif pending_refunds>0 then state:='refund_pending';elsif paid_refunds>0 then state:='partially_refunded';else state:='paid';end if;
 update public.gac_orders set payment_status=state where id=i.order_id;
 end if;
 return 'observed';
end $$;
create function public.gac_owner_recovery_status() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.gac_is_owner() then raise exception 'Owner access required' using errcode='42501';end if;
 return (select jsonb_build_object('last_started_at',last_started_at,'last_success_at',last_success_at,'last_error',last_error,'due_jobs',(select count(*) from gac_private.payment_recovery_queue where next_check_at<=clock_timestamp()),'gateway_activity',(select coalesce(jsonb_agg(a),'[]'::jsonb) from(select t.transaction_id,c.callsign as collection,t.kind,t.status,t.amount_cents,t.observed_at from gac_private.gateway_transactions t join gac_private.authorizenet_checkouts i on i.id=t.checkout_id join public.gac_collections c on c.id=i.collection_id order by t.observed_at desc limit 20)a)) from gac_private.payment_recovery_state where singleton);
end $$;
create function gac_private.invoke_payment_recovery() returns bigint language plpgsql security definer set search_path='' as $$
declare endpoint text;token text;request_id bigint;
begin
 select s.endpoint into strict endpoint from gac_private.payment_recovery_state s where singleton;
 select decrypted_secret into strict token from vault.decrypted_secrets where name='gac_payment_recovery_token';
 select net.http_post(url:=endpoint,headers:=jsonb_build_object('Content-Type','application/json','x-gac-recovery-token',token),body:='{}'::jsonb,timeout_milliseconds:=100000) into request_id;
 return request_id;
end $$;
revoke all on function gac_private.invoke_payment_recovery() from public,anon,authenticated;
revoke all on function public.gac_verify_recovery_token(text),public.gac_claim_payment_recovery(),public.gac_checkpoint_payment_recovery(uuid,jsonb,timestamptz,boolean,boolean),public.gac_enqueue_payment_recovery(jsonb),public.gac_due_payment_recovery(),public.gac_finish_payment_recovery(text,boolean,boolean),public.gac_observe_gateway_transaction(text,text,text,text,text,integer) from public,anon,authenticated;
grant execute on function public.gac_verify_recovery_token(text),public.gac_claim_payment_recovery(),public.gac_checkpoint_payment_recovery(uuid,jsonb,timestamptz,boolean,boolean),public.gac_enqueue_payment_recovery(jsonb),public.gac_due_payment_recovery(),public.gac_finish_payment_recovery(text,boolean,boolean),public.gac_observe_gateway_transaction(text,text,text,text,text,integer) to service_role;
revoke all on function public.gac_owner_recovery_status() from public,anon;
grant execute on function public.gac_owner_recovery_status() to authenticated;
-- Scheduling is enabled separately after the Edge Function has passed its sandbox checks.
commit;
