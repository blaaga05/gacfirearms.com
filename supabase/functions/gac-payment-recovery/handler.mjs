import {authorize,backend,gatewayConfig,cents} from '../_shared/authorizenet.mjs';
const invoicePattern=/^GAC[a-f\d]{17}$/;
const rows=value=>value==null?[]:Array.isArray(value)?value:(()=>{throw Error('Invalid gateway page')})();
const iso=date=>new Date(date).toISOString().replace(/\.\d{3}Z$/,'Z');
export async function observeTransaction(env,t,fetcher=fetch){
 const tx=String(t?.transId||'');if(!/^\d{1,30}$/.test(tx))throw Error('Invalid transaction details');
 const db=backend(env,fetcher),invoice=t.order?.invoiceNumber,reference=t.refTransId?String(t.refTransId):null;
 const amount=cents(t.settleAmount??t.authAmount??0),status=String(t.transactionStatus||'unknown'),kind=String(t.transactionType||'unknown');let outcome='ignored';
 if(invoicePattern.test(invoice||'')&&kind==='authCaptureTransaction'){
  const approved=String(t.responseCode)==='1'&&!t.splitTenderId;
  outcome=await db('gac_apply_authorizenet_payment',{p_transaction:tx,p_invoice:invoice,p_amount_cents:amount,p_paid_at:t.submitTimeUTC,p_status:approved?status:'unapproved:'+status,p_currency:'usd'});
 }
 await db('gac_observe_gateway_transaction',{p_transaction:tx,p_invoice:invoicePattern.test(invoice||'')?invoice:null,p_reference:reference&&/^\d{1,30}$/.test(reference)?reference:null,p_kind:kind,p_status:status,p_amount_cents:amount});
 return {outcome,terminal:['settledSuccessfully','voided','declined','expired','refundSettledSuccessfully'].includes(status)};
}
export async function runRecovery({env,fetcher=fetch,now=()=>Date.now()}){
 gatewayConfig(env);const db=backend(env,fetcher),state=await db('gac_claim_payment_recovery',{});if(!state)return{busy:true};
 const deadline=now()+75000;let cursor=state.cursor,scanFrom=state.scan_from,checked=0,recovered=0,failures=0,pages=0,step='start';
 const checkpoint=(finished=false,error=false)=>(step='checkpoint',db('gac_checkpoint_payment_recovery',{p_lease:state.lease,p_cursor:cursor,p_scan_from:scanFrom,p_finished:finished,p_error:error}));
 const report=(name,args)=>{step=name;return authorize(env,name,args,fetcher,true);};
 const enqueue=async list=>{await db('gac_enqueue_payment_recovery',{p_candidates:list.map(t=>({id:String(t.transId),invoice:t.invoiceNumber||null,status:t.transactionStatus||null}))});};
 try{
  // Retry durable webhook notifications first; failure leaves each notification pending.
  const pending=await db('gac_pending_authorizenet_notifications',{});
  const {processNotification}=await import('../_shared/authorizenet.mjs');
  for(const row of pending){if(now()>deadline)break;try{await processNotification(env,{notificationId:row.notification_id,payload:{id:row.transaction_id}},fetcher)}catch{failures++;}}
  // Each successful page is checkpointed only after its transaction IDs are durably queued.
  while(pages<4&&now()<deadline-25000){
   if(cursor.stage==='unsettled'){
    const page=await report('getUnsettledTransactionListRequest',{sorting:{orderBy:'submitTimeUTC',orderDescending:true},paging:{limit:100,offset:cursor.page||1}});const list=rows(page.transactions);await enqueue(list);pages++;
    cursor=list.length===100?{stage:'unsettled',page:(cursor.page||1)+1}:{stage:'batches'};await checkpoint();
   }else if(cursor.stage==='batches'){
    const end=iso(Math.min(new Date(scanFrom).getTime()+7*86400000,now()));const data=await report('getSettledBatchListRequest',{includeStatistics:false,firstSettlementDate:iso(scanFrom),lastSettlementDate:end});
    cursor={stage:'batch',batches:rows(data.batchList).map(x=>String(x.batchId)).filter(x=>/^\d{1,30}$/.test(x)),index:0,page:1,end};await checkpoint();
   }else if(cursor.stage==='batch'){
    if(cursor.index>=cursor.batches.length){const end=new Date(cursor.end).getTime();scanFrom=iso(end>=now()-60000?end-86400000:end);cursor={stage:'unsettled',page:1};await checkpoint();break;}
    const page=await report('getTransactionListRequest',{batchId:cursor.batches[cursor.index],sorting:{orderBy:'submitTimeUTC',orderDescending:false},paging:{limit:100,offset:cursor.page}});const list=rows(page.transactions);await enqueue(list);pages++;
    cursor=list.length===100?{...cursor,page:cursor.page+1}:{...cursor,index:cursor.index+1,page:1};await checkpoint();
   }else throw Error('Invalid recovery cursor');
  }
  step='due-queue';const due=await db('gac_due_payment_recovery',{});
  for(const job of due){if(now()>deadline)break;let terminal=false,ok=false;try{const data=await authorize(env,'getTransactionDetailsRequest',{transId:job.transaction_id},fetcher);if(String(data.transaction?.transId)!==job.transaction_id)throw Error('Mismatching transaction');const result=await observeTransaction(env,data.transaction,fetcher);terminal=result.terminal;ok=true;checked++;if(result.outcome==='credited')recovered++;}catch{failures++;}step='finish-queue';await db('gac_finish_payment_recovery',{p_transaction:job.transaction_id,p_ok:ok,p_terminal:terminal});}
  await checkpoint(true,failures>0);return{checked,recovered,failures,pages};
 }catch(error){const failedStep=step;try{await checkpoint(true,true)}catch{}throw Object.assign(Error('Payment recovery incomplete; retry required'),{phase:failedStep,code:error.code,errorType:error.name});}
}
export function createRecoveryHandler({env,fetcher=fetch}){return async req=>{
 const origin=env('GAC_SITE_ORIGIN')||'https://gacfirearms.com';const headers={'Content-Type':'application/json','Cache-Control':'no-store','Access-Control-Allow-Origin':origin,'Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS','Vary':'Origin'};const reply=(x,status=200)=>new Response(JSON.stringify(x),{status,headers});
 if(req.headers.get('origin')&&req.headers.get('origin')!==origin)return reply({error:'Origin not allowed'},403);
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});if(req.method!=='POST')return reply({error:'POST required'},405);
 try{
  const token=req.headers.get('x-gac-recovery-token');let allowed=false;
  if(token&&/^[a-f0-9]{64}$/.test(token))allowed=await backend(env,fetcher)('gac_verify_recovery_token',{p_token:token})===true;
  if(!allowed){const auth=req.headers.get('authorization')||'';if(!/^Bearer \S+$/.test(auth))return reply({error:'Authentication required'},401);const url=env('SUPABASE_URL'),key=env('SUPABASE_ANON_KEY')||JSON.parse(env('SUPABASE_PUBLISHABLE_KEYS')||'{}').default;const h={apikey:key,Authorization:auth,'Content-Type':'application/json'};const u=await fetcher(url+'/auth/v1/user',{headers:h,signal:AbortSignal.timeout(10000)});if(!u.ok)return reply({error:'Sign in again'},401);const o=await fetcher(url+'/rest/v1/rpc/gac_is_owner',{method:'POST',headers:h,body:'{}',signal:AbortSignal.timeout(10000)});if(!o.ok||await o.json()!==true)return reply({error:'Owner access required'},403);}
  return reply(await runRecovery({env,fetcher}));
 }catch(error){return reply({error:'Recovery could not finish. The scheduled job will retry; no new charge was made.',stage:error.phase,code:error.code,errorType:error.errorType},503)}
};}
