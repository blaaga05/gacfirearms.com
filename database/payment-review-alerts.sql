begin;
alter table public.gac_messages add column payment_review_transaction text unique references gac_private.authorizenet_payment_reviews(transaction_id);
create index gac_messages_payment_owner_unread on public.gac_messages(available_at) where payment_review_transaction is not null and owner_read_at is null;
create function gac_private.payment_review_message() returns trigger language plpgsql security definer set search_path='' as $$
declare i gac_private.authorizenet_checkouts;group_name text;
begin
 select * into strict i from gac_private.authorizenet_checkouts where id=new.checkout_id;
 select callsign into group_name from public.gac_collections where id=i.collection_id;
 insert into public.gac_messages(member_id,sender_kind,body,payment_review_transaction)
 values(i.user_id,'system','PAYMENT NEEDS GAC REVIEW · '||group_name||' · Numbers '||array_to_string(i.numbers,', ')||'. This payment has not secured these numbers. Do not buy another number or pay again. Message GAC here so we can confirm availability and arrange your number, or void/refund the payment. GAC has been alerted in the owner inbox. Reference: '||new.transaction_id||'. Review reason: '||new.reason,new.transaction_id)
 on conflict(payment_review_transaction) do nothing;
 return new;
end $$;
revoke all on function gac_private.payment_review_message() from public,anon,authenticated;
create trigger gac_payment_review_message after insert on gac_private.authorizenet_payment_reviews for each row execute function gac_private.payment_review_message();
create function public.gac_my_payment_reviews() returns table(checkout_id uuid,transaction_id text,numbers integer[],collection text,reason text) language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.gac_is_member() then raise exception 'Active member access required' using errcode='42501';end if;
 return query select i.id,r.transaction_id,i.numbers,c.callsign,r.reason from gac_private.authorizenet_payment_reviews r join gac_private.authorizenet_checkouts i on i.id=r.checkout_id join public.gac_collections c on c.id=i.collection_id where i.user_id=auth.uid() and r.resolved_at is null order by r.created_at;
end $$;
revoke all on function public.gac_my_payment_reviews() from public,anon;
grant execute on function public.gac_my_payment_reviews() to authenticated;
create or replace function public.gac_mark_messages_read(p_ids uuid[]) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not (public.gac_is_owner() or public.gac_is_member()) then raise exception 'Member access required';end if;
 if coalesce(array_length(p_ids,1),0)>100 then raise exception 'Too many messages';end if;
 if public.gac_is_owner() then update public.gac_messages set owner_read_at=now() where id=any(p_ids) and available_at<=now() and (sender_kind='member' or payment_review_transaction is not null) and owner_read_at is null;
 else update public.gac_messages set member_read_at=now() where id=any(p_ids) and member_id=auth.uid() and available_at<=now() and sender_kind<>'member' and member_read_at is null;end if;
end $$;
create or replace function public.gac_message_unread_count() returns bigint language sql security invoker set search_path='' as $$
 select count(*) from public.gac_messages where available_at<=now() and case when public.gac_is_owner() then (sender_kind='member' or payment_review_transaction is not null) and owner_read_at is null else member_id=auth.uid() and sender_kind<>'member' and member_read_at is null end;
$$;
create or replace function public.gac_message_inbox() returns table(member_id uuid,callsign text,last_body text,last_at timestamptz,unread_count bigint) language plpgsql security invoker set search_path='' as $$
begin
 if not public.gac_is_owner() then raise exception 'Owner access required';end if;
 return query select p.user_id,p.callsign,last_msg.body,last_msg.created_at,(select count(*) from public.gac_messages u where u.member_id=p.user_id and (u.sender_kind='member' or u.payment_review_transaction is not null) and u.owner_read_at is null and u.available_at<=now()) from public.gac_profiles p join lateral(select m.body,m.created_at from public.gac_messages m where m.member_id=p.user_id and m.available_at<=now() order by m.created_at desc,m.id desc limit 1) last_msg on true order by last_msg.created_at desc;
end $$;
commit;
