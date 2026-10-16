import {gatewayConfig} from '../_shared/authorizenet.mjs';
const ORIGIN='https://gacfirearms.com';
export function createHandler({env,fetcher=fetch}){
 return async req=>{
  const ORIGIN=env('GAC_SITE_ORIGIN')||'https://gacfirearms.com';
  const headers={'Content-Type':'application/json','Cache-Control':'no-store','Access-Control-Allow-Origin':ORIGIN,'Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS','Vary':'Origin'};
  const reply=(body,status=200)=>new Response(JSON.stringify(body),{status,headers});
  if(req.headers.get('origin')&&req.headers.get('origin')!==ORIGIN)return reply({error:'Origin not allowed'},403);
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
  if(req.method!=='POST')return reply({error:'Method not allowed'},405);
  const authorization=req.headers.get('authorization')||'';
  if(!/^Bearer \S+$/.test(authorization))return reply({error:'Sign in to your owner account.'},401);
  try{
   const url=env('SUPABASE_URL'),key=env('SUPABASE_ANON_KEY')||JSON.parse(env('SUPABASE_PUBLISHABLE_KEYS')||'{}').default;
   if(!url||!key)return reply({error:'Server configuration unavailable.'},503);
   const call=async(path,options={})=>fetcher(url+path,{...options,headers:{apikey:key,Authorization:authorization,'Content-Type':'application/json'},signal:AbortSignal.timeout(10000)});
   const user=await call('/auth/v1/user');
   if(!user.ok)return reply({error:'Sign in again before checking payments.'},401);
   const identity=await user.json();if(!identity.id)return reply({error:'Sign in again.'},401);
   const owner=await call('/rest/v1/rpc/gac_is_owner',{method:'POST',body:'{}'});
   if(!owner.ok||await owner.json()!==true)return reply({error:'Owner access required.'},403);
   const gateway=gatewayConfig(env),login=gateway.login,transaction=gateway.key,signature=gateway.signature;
   const missing=[];if(!login)missing.push('AUTHORIZENET_API_LOGIN_ID');if(!transaction)missing.push('AUTHORIZENET_TRANSACTION_KEY');if(!signature)missing.push('AUTHORIZENET_SIGNATURE_KEY');
   if(missing.length)return reply({ok:false,message:'Missing Supabase secrets: '+missing.join(', ')});
   if(!/^[a-fA-F0-9]{128}$/.test(signature))return reply({ok:false,message:'The Signature Key must contain 128 hexadecimal characters. Check its saved value in Supabase.'});
   const requestText=await req.text();if(requestText.length>1000)return reply({error:'Request too large'},413);
   let body={};if(requestText){try{body=JSON.parse(requestText)}catch{return reply({error:'Invalid request'},400)}}
   if(body.action==='diagnose'){const {diagnoseHosted}=await import('./diagnostic.mjs');return reply(await diagnoseHosted({env,fetcher}));}
   const response=await fetcher(gateway.api,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({authenticateTestRequest:{merchantAuthentication:{name:login,transactionKey:transaction}}}),signal:AbortSignal.timeout(15000)});
   if(!response.ok)return reply({error:'Authorize.net could not be reached. Try again shortly.'},502);
   const data=JSON.parse((await response.text()).replace(/^\uFEFF/,''));
   if(data.messages?.resultCode!=='Ok'){
    const code=data.messages?.message?.[0]?.code;
    return reply({ok:false,message:code==='E00007'?'Authorize.net rejected the API Login ID or Transaction Key. Check that both are from the configured gateway environment.':'Authorize.net did not validate the credentials. Review your gateway settings and try again.'});
   }
   const notificationStatus=await call('/rest/v1/rpc/gac_owner_payment_notification_status',{method:'POST',body:'{}'});
   const lastNotification=notificationStatus.ok?await notificationStatus.json():null;
   return reply({ok:true,lastNotification,message:(lastNotification?'Signed payment notification received '+lastNotification+'. ':'')+gateway.mode+' Authorize.net credentials verified. Signature Key is saved in the expected format. Member crediting still requires transaction verification. No charge was made. Member checkout remains disabled.'});
  }catch{return reply({error:'Payment connection check could not finish. Try again shortly.'},502)}
 };
}
