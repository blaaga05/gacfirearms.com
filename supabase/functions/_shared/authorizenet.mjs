export const API='https://api.authorize.net/xml/v1/request.api';
const PRODUCTION_PROJECT='https://yuuagwxqhxiiybwjhome.supabase.co';
export function gatewayConfig(env){
 const mode=env('AUTHORIZENET_ENVIRONMENT')||'production';
 if(!['sandbox','production'].includes(mode))throw Error('Invalid payment environment');
 const sandbox=mode==='sandbox';
 // Sandbox payments must never create orders in the production member database.
 if(sandbox&&(!env('AUTHORIZENET_SANDBOX_PROJECT_URL')||env('SUPABASE_URL')!==env('AUTHORIZENET_SANDBOX_PROJECT_URL')||env('SUPABASE_URL')===PRODUCTION_PROJECT))throw Error('Sandbox requires an isolated Supabase project');
 const prefix=sandbox?'AUTHORIZENET_SANDBOX_':'AUTHORIZENET_';
 const origin=env('GAC_SITE_ORIGIN')||'https://gacfirearms.com';
 if(!/^https:\/\/[^/?#]+$/.test(origin))throw Error('Invalid site origin');
 if(sandbox&&origin==='https://gacfirearms.com')throw Error('Sandbox requires an isolated site origin');
 return {mode,origin,api:sandbox?'https://apitest.authorize.net/xml/v1/request.api':API,
 payment:sandbox?'https://test.authorize.net/payment/payment':'https://accept.authorize.net/payment/payment',
 webhooks:sandbox?'https://apitest.authorize.net/rest/v1/webhooks':'https://api.authorize.net/rest/v1/webhooks',
 login:env(prefix+'API_LOGIN_ID')?.trim(),key:env(prefix+'TRANSACTION_KEY')?.trim(),signature:env(prefix+'SIGNATURE_KEY')?.trim()};
}

export function backend(env,fetcher=fetch){
 const url=env('SUPABASE_URL'),key=env('SUPABASE_SERVICE_ROLE_KEY')||JSON.parse(env('SUPABASE_SECRET_KEYS')||'{}').default;
 return async(name,args)=>{if(!url||!key)throw Error('Backend not configured');const r=await fetcher(url+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:key,Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify(args),signal:AbortSignal.timeout(10000)});if(!r.ok)throw Error('Payment database operation failed');return r.json()};
}
export async function authorize(env,name,params,fetcher=fetch){
 const {login,key,api}=gatewayConfig(env);if(!login||!key)throw Error('Payment gateway not configured');
 const r=await fetcher(api,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({[name]:{merchantAuthentication:{name:login,transactionKey:key},...params}}),signal:AbortSignal.timeout(15000)});
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
  // Ledger currency is USD; verify the merchant account currency before rollout.
  const status=String(t.transactionStatus||'unknown');
  const approved=String(t.responseCode)==='1'&&t.transactionType==='authCaptureTransaction'&&!t.splitTenderId;
  const result=await db('gac_apply_authorizenet_payment',{p_transaction:tx,p_invoice:invoice,p_amount_cents:cents(t.settleAmount??t.authAmount),p_paid_at:t.submitTimeUTC,p_status:approved?status:'unapproved:'+status,p_currency:'usd'});
  outcome=result==='credited'?'credited':result==='review'?'review':'ignored';
 }
 await db('gac_finish_authorizenet_notification',{p_notification:data.notificationId,p_outcome:outcome});
 return outcome;
}

export async function liveWebhookReady(env,fetcher=fetch){
 const {login,key,webhooks}=gatewayConfig(env);if(!login||!key)return false;
 const r=await fetcher(webhooks,{headers:{Authorization:'Basic '+btoa(login+':'+key),'Accept':'application/json'},signal:AbortSignal.timeout(10000)});
 if(!r.ok)throw Error('Webhook configuration could not be checked');const rows=await r.json();const expected=env('SUPABASE_URL')+'/functions/v1/gac-authorizenet-webhook';
 return Array.isArray(rows)&&rows.some(x=>x.url===expected&&x.status==='active'&&x.eventTypes?.includes('net.authorize.payment.authcapture.created'));
}
