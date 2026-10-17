begin;
update gac_private.checkout_settings set enabled=true where singleton;
do $$declare o uuid;m uuid:=extensions.gen_random_uuid();g uuid:=extensions.gen_random_uuid();meta jsonb;a uuid;b uuid;inv_a text;inv_b text;notification uuid:=extensions.gen_random_uuid();webhook uuid:=extensions.gen_random_uuid();
begin
 select user_id into strict o from gac_private.owners limit 1;
 select jsonb_build_object('full_name','Synthetic Competition Test','phone','5555550199','age_confirmed',true,'law_agreed',true,'accuracy_confirmed',true,'recognition_acknowledged',true,'requirements_version',version,'minimum_age',minimum_age,'callsign','RACE_'||left(replace(m::text,'-',''),12)) into meta from public.gac_requirements where singleton;
 insert into auth.users(id,email,email_confirmed_at,raw_user_meta_data)values(m,'competition-'||m||'@example.invalid',now(),meta);
 insert into public.gac_collections(id,callsign,quantity,price_cents,state,release_at,is_test)values(g,'COMPETITION_ROLLBACK_FIXTURE',2,100,'open',now()-interval '1 minute',false);
 perform set_config('request.jwt.claim.sub',o::text,true);perform set_config('request.jwt.claims',json_build_object('sub',o,'role','authenticated')::text,true);set local role authenticated;perform public.gac_hold_number(g,1);a:=public.gac_begin_hosted_checkout(g,array[1],true,extensions.gen_random_uuid());reset role;
 perform set_config('request.jwt.claim.sub',m::text,true);perform set_config('request.jwt.claims',json_build_object('sub',m,'role','authenticated')::text,true);set local role authenticated;
 begin perform public.gac_hold_number(g,1);raise exception 'Competing member took held number';exception when raise_exception then if sqlerrm<>'Another member just reserved this number. Choose another number.' then raise;end if;end;
 if exists(select 1 from public.gac_my_hosted_checkout(a)) then raise exception 'Cross-account checkout exposed';end if;
 reset role;perform set_config('request.jwt.claim.sub',o::text,true);perform set_config('request.jwt.claims',json_build_object('sub',o,'role','authenticated')::text,true);set local role authenticated;perform public.gac_release_my_numbers(g,null);reset role;
 -- The second synthetic account is temporarily allowlisted only for the owner-pilot checkout test; everything rolls back.
 insert into gac_private.owners(user_id)values(m);
 perform set_config('request.jwt.claim.sub',m::text,true);perform set_config('request.jwt.claims',json_build_object('sub',m,'role','authenticated')::text,true);set local role authenticated;perform public.gac_hold_number(g,1);b:=public.gac_begin_hosted_checkout(g,array[1],true,extensions.gen_random_uuid());reset role;
 select invoice into inv_a from gac_private.authorizenet_checkouts where id=a;select invoice into inv_b from gac_private.authorizenet_checkouts where id=b;
 perform set_config('request.jwt.claims','{"role":"service_role"}',true);set local role service_role;
 if public.gac_apply_authorizenet_payment('98765551',inv_a,100,now(),'capturedPendingSettlement')<>'review' then raise exception 'First abandoned payment stole second hold';end if;
 if public.gac_apply_authorizenet_payment('98765552',inv_b,100,now(),'capturedPendingSettlement')<>'credited' then raise exception 'Current holder not credited';end if;
 perform public.gac_apply_authorizenet_payment('98765552',inv_b,100,now(),'capturedPendingSettlement');
 perform public.gac_receive_authorizenet_notification(notification,webhook,'net.authorize.payment.authcapture.created','98765552',now());perform public.gac_receive_authorizenet_notification(notification,webhook,'net.authorize.payment.authcapture.created','98765552',now());reset role;
 if (select count(*) from public.gac_numbers where collection_id=g)<>1 or (select user_id from public.gac_numbers where collection_id=g)<>m or (select count(*) from public.gac_orders where collection_id=g)<>1 then raise exception 'Duplicate allocation or incorrect owner';end if;
 if (select count(*) from gac_private.authorizenet_notifications where notification_id=notification)<>1 then raise exception 'Duplicate notification stored';end if;
end $$;
rollback;
