export const API='https://api.authorize.net/xml/v1/request.api';
export function backend(env,fetcher=fetch){
 const url=env('SUPABASE_URL'),key=env('SUPABASE_SERVICE_ROLE_KEY')||JSON.parse(env('SUPABASE_SECRET_KEYS')||'{}').default;
 return async(name,args)=>{if(!url||!key)throw Error('Backend not configured');const r=await fetcher(url+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:key,Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify(args),signal:AbortSignal.timeout(10000)});if(!r.ok)throw Error('Payment database operation failed');return r.json()};
}
export async function authorize(env,name,params,fetcher=fetch){
 const login=env('AUTHORIZENET_API_LOGIN_ID')?.trim(),key=env('AUTHORIZENET_TRANSACTION_KEY')?.trim();if(!login||!key)throw Error('Payment gateway not configured');
 const r=await fetcher(API,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({[name]:{merchantAuthentication:{name:login,transactionKey:key},...params}}),signal:AbortSignal.timeout(15000)});
 if(!r.ok)throw Error('Payment gateway unavailable');const data=JSON.parse((await r.text()).replace(/^\uFEFF/,''));if(data.messages?.resultCode!=='Ok')throw Error('Payment gateway could not complete this request');return data;
}
export function cents(value){const s=String(value);if(!/^\d{1,8}(\.\d{1,2})?$/.test(s))throw Error('Invalid gateway amount');const [a,b='']=s.split('.');return Number(a)*100+Number(b.padEnd(2,'0'));}
export async function processNotification(env,data,fetcher=fetch){
 const db=backend(env,fetcher),tx=String(data.payload?.id||'');
 if(!/^\d{1,30}$/.test(tx))throw Error('Invalid transaction');
 // Reporting failures leave the durable notification pending and request retry.
 let response;
 try{response=await authorize(env,'getTransactionDetailsRequest',{transId:tx},fetcher)}catch(e){throw e}
 const t=response.transaction;
 if(!t||String(t.transId)!==tx)throw Error('Transaction details unavailable');
 const invoice=t.order?.invoiceNumber;
 let outcome='ignored';
 if(typeof invoice==='string'&&/^GAC[a-f\d]{17}$/.test(invoice)){
  // Amount and invoice come exclusively from authenticated gateway reporting.
  // USD was fixed in the signed server-generated token request.
  const status=String(t.transactionStatus||'unknown');
  const approved=String(t.responseCode)==='1'&&t.transactionType==='authCaptureTransaction'&&!t.splitTenderId;
  const result=await db('gac_apply_authorizenet_payment',{p_transaction:tx,p_invoice:invoice,p_amount_cents:cents(t.settleAmount??t.authAmount),p_paid_at:t.submitTimeUTC,p_status:approved?status:'unapproved:'+status,p_currency:'usd'});
  outcome=result==='credited'?'credited':result==='review'?'review':'ignored';
 }
 await db('gac_finish_authorizenet_notification',{p_notification:data.notificationId,p_outcome:outcome});
 return outcome;
}

export async function liveWebhookReady(env,fetcher=fetch){
 const login=env('AUTHORIZENET_API_LOGIN_ID')?.trim(),key=env('AUTHORIZENET_TRANSACTION_KEY')?.trim();if(!login||!key)return false;
 const r=await fetcher('https://api.authorize.net/rest/v1/webhooks',{headers:{Authorization:'Basic '+btoa(login+':'+key),'Accept':'application/json'},signal:AbortSignal.timeout(10000)});
 if(!r.ok)throw Error('Webhook configuration could not be checked');const rows=await r.json();const expected=env('SUPABASE_URL')+'/functions/v1/gac-authorizenet-webhook';
 return Array.isArray(rows)&&rows.some(x=>x.url===expected&&x.status==='active'&&x.eventTypes?.includes('net.authorize.payment.authcapture.created'));
}
