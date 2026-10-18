begin;
update gac_private.checkout_settings set enabled=true where singleton;
do $$declare o uuid;g uuid:=extensions.gen_random_uuid();h uuid:=extensions.gen_random_uuid();k uuid:=extensions.gen_random_uuid();z uuid:=extensions.gen_random_uuid();i uuid;j uuid;inv text;result jsonb;
begin
 select user_id into strict o from gac_private.owners limit 1;
 insert into public.gac_collections(id,callsign,quantity,price_cents,state,release_at,is_test)values(g,'REFUND_RELEASE_FIXTURE',5,100,'open',now()-interval '1 day',false),(h,'REFUND_PROTECTED_FIXTURE',5,100,'open',now()-interval '1 day',false),(k,'REFUND_MISSING_FIXTURE',5,100,'open',now()-interval '1 day',false),(z,'REFUND_CLOSED_FIXTURE',5,100,'open',now()-interval '1 day',false);
 perform set_config('request.jwt.claim.sub',o::text,true);perform set_config('request.jwt.claims','{"role":"service_role"}',true);
 set local role authenticated;perform public.gac_hold_number(g,1);perform public.gac_hold_number(g,2);i:=public.gac_begin_hosted_checkout(g,array[1,2],true,extensions.gen_random_uuid());reset role;select invoice into inv from gac_private.authorizenet_checkouts where id=i;
 set local role service_role;perform public.gac_apply_authorizenet_payment('98768001',inv,200,now(),'capturedPendingSettlement');perform public.gac_observe_gateway_transaction('98768001',inv,null,'authCaptureTransaction','capturedPendingSettlement',200);perform public.gac_observe_gateway_transaction('98768002',inv,'98768001','refundTransaction','refundPendingSettlement',100);reset role;
 if(select count(*)from public.gac_numbers where collection_id=g)<>2 then raise exception 'Partial refund auto released numbers';end if;
 set local role authenticated;result:=public.gac_owner_refund_release('98768001',array[2]);if(result->>'released')<>'1'then raise exception 'Pending partial refund release failed';end if;
 result:=public.gac_owner_refund_release('98768001',array[2]);if(result->>'released')<>'0'then raise exception 'Release replay was not idempotent';end if;
 begin perform public.gac_owner_refund_release('98768001',array[1]);raise exception 'Refund budget exceeded';exception when raise_exception then if position('insufficient'in sqlerrm)=0 then raise;end if;end;reset role;
 if not exists(select 1 from public.gac_numbers where collection_id=g and edition_number=1)or exists(select 1 from public.gac_numbers where collection_id=g and edition_number=2)then raise exception 'Partial refund removed wrong number';end if;
 set local role service_role;perform public.gac_observe_gateway_transaction('98768003',inv,'98768001','refundTransaction','refundPendingSettlement',100);reset role;
 if exists(select 1 from public.gac_numbers where collection_id=g)then raise exception 'Full pending refund did not auto release remaining number';end if;
 if(select jsonb_array_length(purchased_numbers)from public.gac_orders where payment_reference='AUTHNET-98768001')<>2 then raise exception 'Refund lost receipt';end if;
 set local role authenticated;perform public.gac_owner_assign_number(g,o,2,'complimentary','Later purchaser fixture','',extensions.gen_random_uuid());reset role;
 set local role service_role;perform public.gac_observe_gateway_transaction('98768002',inv,'98768001','refundTransaction','voided',0);perform public.gac_observe_gateway_transaction('98768002',inv,'98768001','refundTransaction','voided',0);reset role;
 if not exists(select 1 from public.gac_numbers where collection_id=g and edition_number=2)or(select count(*)from public.gac_messages where payment_review_transaction='98768002')<>1 then raise exception 'Failed refund reclaimed a later number or alert duplicated';end if;
 -- A previously protected review payment still needs explicit owner release.
 set local role authenticated;perform public.gac_hold_number(h,1);i:=public.gac_begin_hosted_checkout(h,array[1],true,extensions.gen_random_uuid());reset role;select invoice into inv from gac_private.authorizenet_checkouts where id=i;
 set local role service_role;perform public.gac_apply_authorizenet_payment('98768004',inv,100,now(),'unapproved:FDSAuthorizedPendingReview');perform public.gac_apply_authorizenet_payment('98768004',inv,100,now(),'capturedPendingSettlement');perform public.gac_observe_gateway_transaction('98768004',inv,null,'authCaptureTransaction','capturedPendingSettlement',100);perform public.gac_observe_gateway_transaction('98768005',inv,'98768004','refundTransaction','refundPendingSettlement',100);reset role;
 if not exists(select 1 from public.gac_numbers where collection_id=h and edition_number=1)then raise exception 'Protected refund auto released';end if;
 set local role authenticated;perform public.gac_owner_refund_release('98768004',array[1]);reset role;
 if exists(select 1 from public.gac_numbers where collection_id=h)then raise exception 'Protected manual pending refund release failed';end if;
 -- A partial refund can resolve a missing original number without a second charge.
 set local role authenticated;perform public.gac_hold_number(k,1);perform public.gac_hold_number(k,2);i:=public.gac_begin_hosted_checkout(k,array[1,2],true,extensions.gen_random_uuid());reset role;select invoice into inv from gac_private.authorizenet_checkouts where id=i;
 update gac_private.authorizenet_checkouts set created_at=now()-interval '5 minutes',expires_at=now()-interval '1 minute',payment_checked_at=now()where id=i;update gac_private.number_holds set expires_at=now()-interval '1 minute'where collection_id=k;
 set local role authenticated;perform public.gac_owner_assign_number(k,o,2,'complimentary','Competing assignment','',extensions.gen_random_uuid());reset role;
 set local role service_role;perform public.gac_apply_authorizenet_payment('98768006',inv,200,now(),'capturedPendingSettlement');perform public.gac_observe_gateway_transaction('98768006',inv,null,'authCaptureTransaction','capturedPendingSettlement',200);perform public.gac_observe_gateway_transaction('98768007',inv,'98768006','refundTransaction','refundPendingSettlement',100);reset role;
 set local role authenticated;perform public.gac_owner_refund_release('98768006',array[2]);reset role;
 if not exists(select 1 from public.gac_numbers where collection_id=k and edition_number=1)or(select count(*)from public.gac_orders where payment_reference='AUTHNET-98768006')<>1 then raise exception 'Partial refund did not fulfill retained original';end if;
 set local role service_role;perform public.gac_apply_authorizenet_payment('98768006',inv,200,now(),'capturedPendingSettlement');reset role;
 if(select count(*)from public.gac_orders where payment_reference='AUTHNET-98768006')<>1 then raise exception 'Refund completion duplicated order';end if;
 -- Closed history cannot be changed even after a full pending refund.
 set local role authenticated;perform public.gac_hold_number(z,1);i:=public.gac_begin_hosted_checkout(z,array[1],true,extensions.gen_random_uuid());reset role;select invoice into inv from gac_private.authorizenet_checkouts where id=i;
 set local role service_role;perform public.gac_apply_authorizenet_payment('98768008',inv,100,now(),'capturedPendingSettlement');reset role;update public.gac_collections set state='closed'where id=z;
 set local role service_role;perform public.gac_observe_gateway_transaction('98768009',inv,'98768008','refundTransaction','refundPendingSettlement',100);reset role;
 set local role authenticated;begin perform public.gac_owner_refund_release('98768008',array[1]);raise exception 'Closed history changed';exception when raise_exception then if position('Closed or recognized'in sqlerrm)=0 then raise;end if;end;reset role;
 if not exists(select 1 from public.gac_numbers where collection_id=z and edition_number=1)then raise exception 'Closed refund auto removed number';end if;
 perform set_config('request.jwt.claim.sub',extensions.gen_random_uuid()::text,true);set local role authenticated;begin perform public.gac_owner_refund_release('98768008',array[1]);raise exception 'Nonowner release succeeded';exception when insufficient_privilege then null;end;reset role;
 if has_table_privilege('authenticated','gac_private.refund_number_releases','select')then raise exception 'Private release audit exposed';end if;
end $$;
rollback;
