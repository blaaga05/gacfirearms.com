begin;
create table gac_private.checkout_settings(singleton boolean primary key default true check(singleton),enabled boolean not null default false,updated_at timestamptz not null default now(),updated_by uuid references auth.users(id));
insert into gac_private.checkout_settings(singleton,enabled) values(true,false);
alter table gac_private.checkout_settings enable row level security;
revoke all on gac_private.checkout_settings from public,anon,authenticated;
create function public.gac_checkout_enabled() returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and public.gac_is_member() and coalesce((select enabled from gac_private.checkout_settings where singleton),false);
$$;
revoke all on function public.gac_checkout_enabled() from public,anon;
grant execute on function public.gac_checkout_enabled() to authenticated;
create function public.gac_owner_set_checkout_enabled(p_enabled boolean) returns boolean language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.gac_is_owner() then raise exception 'Owner access required' using errcode='42501';end if;
 if p_enabled is null then raise exception 'Choose enabled or disabled';end if;
 update gac_private.checkout_settings set enabled=p_enabled,updated_at=clock_timestamp(),updated_by=auth.uid() where singleton;
 if not found then raise exception 'Checkout settings unavailable';end if;
 return p_enabled;
end $$;
revoke all on function public.gac_owner_set_checkout_enabled(boolean) from public,anon;
grant execute on function public.gac_owner_set_checkout_enabled(boolean) to authenticated;
create or replace function public.gac_begin_hosted_checkout(p_collection uuid,p_numbers integer[],p_acknowledged boolean,p_request uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare c public.gac_collections;p public.gac_profiles;i gac_private.authorizenet_checkouts;nums integer[];tokens uuid[];deadline timestamptz;
begin
 -- Owner pilot is enforced server-side. Member rollout requires a separate change.
 if auth.uid() is null or not public.gac_is_owner() then raise exception 'Hosted checkout is in owner testing' using errcode='42501';end if;
 if not public.gac_checkout_enabled() then raise exception 'Checkout temporarily unavailable. GAC is not accepting new payments.' using errcode='55000';end if;
 if p_acknowledged is distinct from true or p_request is null then raise exception 'Purchase acknowledgment required';end if;
 select * into strict c from public.gac_collections where id=p_collection for update;
 if c.is_test or c.archived_at is not null or c.state<>'open' or c.release_at>clock_timestamp() or c.recognition_at<=clock_timestamp() then raise exception 'Choose an open live collection';end if;
 select * into strict p from public.gac_profiles where user_id=auth.uid();
 if p.status<>'active' or not exists(select 1 from auth.users where id=p.user_id and email_confirmed_at is not null) then raise exception 'Active verified membership required';end if;
 select array_agg(x order by x) into nums from unnest(p_numbers)x;
 if coalesce(cardinality(nums),0)<1 or cardinality(nums)>200 or (select count(distinct x) from unnest(nums)x)<>cardinality(nums) then raise exception 'Select distinct numbers';end if;
 -- A released, expired, or replaced hold must not keep a member locked to an abandoned form.
 -- Preserve the intent/invoice so any late payment still reconciles into owner review.
 update gac_private.authorizenet_checkouts a set status='expired',token=null
 where a.user_id=p.user_id and a.collection_id=c.id and a.status='pending'
 and (a.expires_at<=clock_timestamp() or
  (select array_agg(h.hold_id order by h.edition_number) from gac_private.number_holds h
   where h.collection_id=a.collection_id and h.user_id=a.user_id
   and h.edition_number=any(a.numbers) and h.expires_at>clock_timestamp()) is distinct from a.hold_ids);
 select * into i from gac_private.authorizenet_checkouts where request_id=p_request;
 if found then
  if i.user_id<>p.user_id or i.collection_id<>c.id or i.numbers is distinct from nums then raise exception 'Checkout request conflict';end if;
  if i.status<>'pending' or i.expires_at<=clock_timestamp() then raise exception 'This checkout expired or has already been processed';end if;
  return i.id;
 end if;
 select * into i from gac_private.authorizenet_checkouts where user_id=p.user_id and collection_id=c.id and status='pending' and expires_at>clock_timestamp() order by created_at desc limit 1;
 if found then
  if i.numbers is distinct from nums then raise exception 'An earlier checkout is still open. Finish it or wait for its hold to expire before changing this cart.';end if;
  return i.id;
 end if;
 select array_agg(h.hold_id order by h.edition_number),min(h.expires_at) into tokens,deadline from gac_private.number_holds h where h.collection_id=c.id and h.user_id=p.user_id and h.edition_number=any(nums) and h.expires_at>clock_timestamp();
 if coalesce(cardinality(tokens),0)<>cardinality(nums) or exists(select 1 from unnest(nums)x where x<1 or x>c.quantity) or exists(select 1 from public.gac_numbers where collection_id=c.id and edition_number=any(nums)) then raise exception 'Your number holds changed. Refresh and select available numbers again.';end if;
 if deadline<clock_timestamp()+interval '90 seconds' then raise exception 'Less than 90 seconds remains on your hold. Wait for it to expire, then select numbers again.';end if;
 insert into gac_private.authorizenet_checkouts(request_id,user_id,collection_id,numbers,hold_ids,amount_cents,currency,acknowledgment,callsign,expires_at)
 values(p_request,p.user_id,c.id,nums,tokens,c.price_cents*cardinality(nums),c.currency,(select recognition_statement from public.gac_requirements where singleton),p.callsign,deadline) returning id into i.id;
 return i.id;
end $$;
commit;
