import {authorize,backend,liveWebhookReady} from '../_shared/authorizenet.mjs';
const ORIGIN='https://gacfirearms.com';
export function hostedSettings(id){const setting=(settingName,value)=>({settingName,settingValue:JSON.stringify(value)});return {setting:[
 setting('hostedPaymentReturnOptions',{showReceipt:true,url:ORIGIN+'/account.html?checkout='+id+'&payment=return',urlText:'Return to GAC',cancelUrl:ORIGIN+'/account.html?checkout='+id+'&payment=cancel',cancelUrlText:'Return to GAC'}),
 setting('hostedPaymentButtonOptions',{text:'Pay'}),setting('hostedPaymentStyleOptions',{bgColor:'#355540'}),
 setting('hostedPaymentPaymentOptions',{cardCodeRequired:true,showCreditCard:true,showBankAccount:false}),
 setting('hostedPaymentSecurityOptions',{captcha:true}),setting('hostedPaymentShippingAddressOptions',{show:false,required:false}),
 setting('hostedPaymentBillingAddressOptions',{show:true,required:true}),setting('hostedPaymentCustomerOptions',{showEmail:false,requiredEmail:false,addPaymentProfile:false}),
 setting('hostedPaymentOrderOptions',{show:true,merchantName:'Gassett Arms Company'})]};}
export function createCheckoutHandler({env,fetcher=fetch}){return async req=>{
 const headers={'Content-Type':'application/json','Cache-Control':'no-store','Access-Control-Allow-Origin':ORIGIN,'Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS','Vary':'Origin'},reply=(body,status=200)=>new Response(JSON.stringify(body),{status,headers});
 if(req.headers.get('origin')&&req.headers.get('origin')!==ORIGIN)return reply({error:'Origin not allowed'},403);
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});if(req.method!=='POST')return reply({error:'POST required'},405);
 const auth=req.headers.get('authorization')||'';if(!/^Bearer \S+$/.test(auth))return reply({error:'Sign in required'},401);
 try{
 const url=env('SUPABASE_URL'),key=env('SUPABASE_ANON_KEY')||JSON.parse(env('SUPABASE_PUBLISHABLE_KEYS')||'{}').default;
 const call=(path,body)=>fetcher(url+path,{method:body?'POST':'GET',headers:{apikey:key,Authorization:auth,'Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(10000)});
 const u=await call('/auth/v1/user');if(!u.ok)return reply({error:'Sign in again'},401);const user=await u.json();
 const owner=await call('/rest/v1/rpc/gac_is_owner',{});if(!owner.ok||await owner.json()!==true)return reply({error:'Hosted checkout is in owner testing'},403);
 const text=await req.text();if(text.length>5000)return reply({error:'Request too large'},413);let body;try{body=JSON.parse(text)}catch{return reply({error:'Invalid request'},400)}
 const db=backend(env,fetcher);
 if(body.action==='reconcile'){
  const {processNotification}=await import('../_shared/authorizenet.mjs');const pending=await db('gac_pending_authorizenet_notifications',{});let processed=0;
  for(const row of pending){try{await processNotification(env,{notificationId:row.notification_id,payload:{id:row.transaction_id}},fetcher);processed++}catch{/* Remains durable and pending for next retry. */}}
  return reply({processed,pending:pending.length,message:'Checked '+pending.length+' saved notifications; '+processed+' completed. No new charge was made.'});
 }
 if(!await liveWebhookReady(env,fetcher))return reply({error:'Activate the GAC Website webhook in Authorize.net before opening live checkout.'},409);
 const begin=await call('/rest/v1/rpc/gac_begin_hosted_checkout',{p_collection:body.collection,p_numbers:body.numbers,p_acknowledged:body.acknowledged===true,p_request:body.request});
 if(!begin.ok){const e=await begin.json();return reply({error:typeof e.message==='string'?e.message:'Checkout could not start'},409)}
 const id=await begin.json(),i=await db('gac_hosted_checkout_token',{p_checkout:id,p_member:user.id});
 let token=i.token;
 if(!token){const data=await authorize(env,'getHostedPaymentPageRequest',{refId:i.invoice,transactionRequest:{transactionType:'authCaptureTransaction',amount:(i.amount_cents/100).toFixed(2),currencyCode:'USD',order:{invoiceNumber:i.invoice}},hostedPaymentSettings:hostedSettings(id)},fetcher);token=data.token;if(typeof token!=='string'||token.length<10)throw Error('Hosted payment token unavailable');await db('gac_hosted_checkout_token',{p_checkout:id,p_member:user.id,p_token:token});}
 return reply({checkout:id,token,url:'https://accept.authorize.net/payment/payment',expires_at:i.expires_at,amount_cents:i.amount_cents});
 }catch{return reply({error:'Secure checkout could not be prepared. Your existing holds have not been extended. Try again shortly.'},502)}
};}
