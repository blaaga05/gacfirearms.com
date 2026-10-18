import {authorize,backend,liveWebhookReady,gatewayConfig} from '../_shared/authorizenet.mjs';
const ORIGIN='https://gacfirearms.com';
export function hostedSettings(id,origin=ORIGIN){const setting=(settingName,value)=>({settingName,settingValue:JSON.stringify(value)});return {setting:[
 setting('hostedPaymentReturnOptions',{showReceipt:true,url:origin+'/account.html',urlText:'Return to GAC',cancelUrl:origin+'/account.html',cancelUrlText:'Return to GAC'}),
 setting('hostedPaymentButtonOptions',{text:'Pay'}),setting('hostedPaymentStyleOptions',{bgColor:'#355540'}),
 setting('hostedPaymentPaymentOptions',{cardCodeRequired:true,showCreditCard:true,showBankAccount:false}),
 setting('hostedPaymentSecurityOptions',{captcha:true}),setting('hostedPaymentShippingAddressOptions',{show:false,required:false}),
 setting('hostedPaymentBillingAddressOptions',{show:true,required:true}),setting('hostedPaymentCustomerOptions',{showEmail:false,requiredEmail:false,addPaymentProfile:false}),
 setting('hostedPaymentOrderOptions',{show:true,merchantName:'Gassett Arms Company'})]};}
export function createCheckoutHandler({env,fetcher=fetch}){return async req=>{
 const ORIGIN=env('GAC_SITE_ORIGIN')||'https://gacfirearms.com';
 const headers={'Content-Type':'application/json','Cache-Control':'no-store','Access-Control-Allow-Origin':ORIGIN,'Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS','Vary':'Origin'},reply=(body,status=200)=>new Response(JSON.stringify(body),{status,headers});
 if(req.headers.get('origin')&&req.headers.get('origin')!==ORIGIN)return reply({error:'Origin not allowed'},403);
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});if(req.method!=='POST')return reply({error:'POST required'},405);
 const recoveryToken=req.headers.get('x-gac-recovery-token');
 if(recoveryToken){try{
  if(!/^[a-f0-9]{64}$/.test(recoveryToken)||await backend(env,fetcher)('gac_verify_recovery_token',{p_token:recoveryToken})!==true)return reply({error:'Internal authentication required'},403);
  const gateway=gatewayConfig(env),signatureReady=/^[a-fA-F0-9]{128}$/.test(gateway.signature||'');
  const credentials=await authorize(env,'authenticateTestRequest',{},fetcher);
  const webhookReady=await liveWebhookReady(env,fetcher);
  const data=await authorize(env,'getHostedPaymentPageRequest',{transactionRequest:{transactionType:'authCaptureTransaction',amount:'1.00',order:{invoiceNumber:'DIAG'+crypto.randomUUID().replaceAll('-','').slice(0,16)}},hostedPaymentSettings:hostedSettings(crypto.randomUUID(),gateway.origin)},fetcher);
  if(typeof data.token!=='string')throw Error('No hosted form');
  const page=await fetcher(gateway.payment,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({token:data.token}).toString(),signal:AbortSignal.timeout(15000)});
  const html=await page.text(),formReady=page.ok&&!(html.match(/g_errorPanelMessage\s*=\s*"([^"]*)"/)?.[1]||'').trim()&&/g_merchantData\s*=\s*\{/.test(html);
  return reply({ok:signatureReady&&webhookReady&&formReady,environment:gateway.mode,credentialsReady:credentials.messages?.resultCode==='Ok',signatureReady,webhookReady,formReady,formStatus:page.status,formError:!!(html.match(/g_errorPanelMessage\s*=\s*"([^\"]*)"/)?.[1]||'').trim(),noCharge:true});
 }catch{return reply({ok:false,error:'Live preflight could not finish; no charge was made.'},502);}}
 const auth=req.headers.get('authorization')||'';if(!/^Bearer \S+$/.test(auth))return reply({error:'Sign in required'},401);
 try{
 const url=env('SUPABASE_URL'),key=env('SUPABASE_ANON_KEY')||JSON.parse(env('SUPABASE_PUBLISHABLE_KEYS')||'{}').default;
 const call=(path,body)=>fetcher(url+path,{method:body?'POST':'GET',headers:{apikey:key,Authorization:auth,'Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(10000)});
 const u=await call('/auth/v1/user');if(!u.ok)return reply({error:'Sign in again'},401);const user=await u.json();
 const membership=await call('/rest/v1/rpc/gac_is_member',{});if(!membership.ok||await membership.json()!==true)return reply({error:'Active membership required'},403);
 const text=await req.text();if(text.length>5000)return reply({error:'Request too large'},413);let body;try{body=JSON.parse(text)}catch{return reply({error:'Invalid request'},400)}
 const db=backend(env,fetcher);
 if(body.action==='reconcile'){
  const owner=await call('/rest/v1/rpc/gac_is_owner',{});if(!owner.ok||await owner.json()!==true)return reply({error:'Owner access required'},403);
  const {processNotification}=await import('../_shared/authorizenet.mjs');const pending=await db('gac_pending_authorizenet_notifications',{});let processed=0;
  for(const row of pending){try{await processNotification(env,{notificationId:row.notification_id,payload:{id:row.transaction_id}},fetcher);processed++}catch{/* Remains durable and pending for next retry. */}}
  return reply({processed,pending:pending.length,message:'Checked '+pending.length+' saved notifications; '+processed+' completed. No new charge was made.'});
 }
 const gateway=gatewayConfig(env);
 const checkoutEnabled=await call('/rest/v1/rpc/gac_checkout_enabled',{});if(!checkoutEnabled.ok||await checkoutEnabled.json()!==true)return reply({error:'Checkout temporarily unavailable. GAC is not accepting new payments.'},409);
 if(!await liveWebhookReady(env,fetcher))return reply({error:'Activate the GAC Website webhook in Authorize.net before opening live checkout.'},409);
 const begin=await call('/rest/v1/rpc/gac_begin_hosted_checkout',{p_collection:body.collection,p_numbers:body.numbers,p_acknowledged:body.acknowledged===true,p_request:body.request});
 if(!begin.ok){const e=await begin.json();return reply({error:typeof e.message==='string'?e.message:'Checkout could not start'},409)}
 const id=await begin.json(),i=await db('gac_hosted_checkout_token',{p_checkout:id,p_member:user.id});
 let token=i.token;
 if(!token){const data=await authorize(env,'getHostedPaymentPageRequest',{refId:i.invoice,transactionRequest:{transactionType:'authCaptureTransaction',amount:(i.amount_cents/100).toFixed(2),order:{invoiceNumber:i.invoice}},hostedPaymentSettings:hostedSettings(id,gateway.origin)},fetcher);token=data.token;if(typeof token!=='string'||token.length<10)throw Error('Hosted payment token unavailable');await db('gac_hosted_checkout_token',{p_checkout:id,p_member:user.id,p_token:token});}
 return reply({checkout:id,token,url:gateway.payment,environment:gateway.mode,expires_at:i.expires_at,amount_cents:i.amount_cents});
 }catch{return reply({error:'Secure checkout could not be prepared. Your existing holds have not been extended. Try again shortly.'},502)}
};}
