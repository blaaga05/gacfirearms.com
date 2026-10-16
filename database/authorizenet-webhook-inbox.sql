begin;
create table gac_private.authorizenet_notifications (
 notification_id uuid primary key,
 webhook_id uuid not null,
 event_type text not null check (event_type like 'net.authorize.payment.%' and length(event_type)<=100),
 transaction_id text not null check (transaction_id ~ '^[0-9]{1,30}$'),
 event_at timestamptz,
 received_at timestamptz not null default clock_timestamp(),
 processed_at timestamptz,
 processing_status text not null default 'pending' check(processing_status in ('pending','credited','ignored','review'))
);
alter table gac_private.authorizenet_notifications enable row level security;
revoke all on gac_private.authorizenet_notifications from public,anon,authenticated;
create index authorizenet_notifications_pending on gac_private.authorizenet_notifications(received_at) where processed_at is null;
create function public.gac_receive_authorizenet_notification(p_notification uuid,p_webhook uuid,p_event text,p_transaction text,p_event_at timestamptz)
returns void language plpgsql security definer set search_path='' as $$
begin
 if (select auth.role()) is distinct from 'service_role' then raise exception 'Service access required';end if;
 insert into gac_private.authorizenet_notifications(notification_id,webhook_id,event_type,transaction_id,event_at)
 values(p_notification,p_webhook,p_event,p_transaction,p_event_at) on conflict(notification_id) do nothing;
end $$;
revoke all on function public.gac_receive_authorizenet_notification(uuid,uuid,text,text,timestamptz) from public,anon,authenticated;
grant execute on function public.gac_receive_authorizenet_notification(uuid,uuid,text,text,timestamptz) to service_role;
create function public.gac_owner_payment_notification_status()
returns timestamptz language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.gac_is_owner() then raise exception 'Owner access required';end if;
 return (select max(received_at) from gac_private.authorizenet_notifications);
end $$;
revoke all on function public.gac_owner_payment_notification_status() from public,anon;
grant execute on function public.gac_owner_payment_notification_status() to authenticated;
commit;
