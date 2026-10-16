import {processNotification,gatewayConfig} from '../_shared/authorizenet.mjs';
const hexBytes=s=>Uint8Array.from(s.match(/../g)||[],x=>parseInt(x,16));
export async function validSignature(raw,header,secret){
 if(!/^[a-f\d]{128}$/i.test(secret||'')||!/^sha512=[a-f\d]{128}$/i.test(header||''))return false;
 const received=hexBytes(header.slice(7));
 // Webhook implementations use the displayed key text; support hex-decoded key
 // representation as well. Both verify HMAC possession of the same secret.
 for(const bytes of [new TextEncoder().encode(secret),hexBytes(secret)]){
  const key=await crypto.subtle.importKey('raw',bytes,{name:'HMAC',hash:'SHA-512'},false,['verify']);
  if(await crypto.subtle.verify('HMAC',key,received,raw))return true;
 }
 return false;
}
export function createWebhookHandler({env,fetcher=fetch,processor=processNotification}){
 return async req=>{
  const reply=(message,status)=>new Response(JSON.stringify({message}),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
  if(req.method!=='POST')return reply('POST required',405);
  try{
   if(Number(req.headers.get('content-length'))>32768)return reply('Payload too large',413);
   const reader=req.body?.getReader();if(!reader)return reply('Body required',400);const chunks=[];let length=0;
   while(true){const {value,done}=await reader.read();if(done)break;length+=value.length;if(length>32768){await reader.cancel();return reply('Payload too large',413)}chunks.push(value)}
   const raw=new Uint8Array(length);let offset=0;for(const x of chunks){raw.set(x,offset);offset+=x.length}
   const signature=gatewayConfig(env).signature;if(!signature)return reply('Not configured',503);
   if(!await validSignature(raw,req.headers.get('x-anet-signature'),signature))return reply('Invalid signature',401);
   let data;try{data=JSON.parse(new TextDecoder().decode(raw))}catch{return reply('Invalid JSON',400)}
   const uuid=/^[a-f\d]{8}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{12}$/i;
   if(typeof data.eventType!=='string'||!data.eventType.startsWith('net.authorize.payment.'))return reply('Ignored event',200);
   if(!uuid.test(data.notificationId||'')||!uuid.test(data.webhookId||'')||data.payload?.entityName!=='transaction'||!/^\d{1,30}$/.test(String(data.payload?.id||'')))return reply('Invalid payment notification',400);
   const eventAt=data.eventDate?new Date(data.eventDate):null;if(eventAt&&!Number.isFinite(eventAt.getTime()))return reply('Invalid event date',400);
   const url=env('SUPABASE_URL'),key=env('SUPABASE_SERVICE_ROLE_KEY')||JSON.parse(env('SUPABASE_SECRET_KEYS')||'{}').default;
   if(!url||!key)return reply('Not configured',503);
   // Acknowledge only after durable deduplicated storage. Never save card data or
   // trust webhook amount/return URL as proof of a purchase. Crediting is separate.
   const stored=await fetcher(url+'/rest/v1/rpc/gac_receive_authorizenet_notification',{method:'POST',headers:{apikey:key,Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify({p_notification:data.notificationId,p_webhook:data.webhookId,p_event:data.eventType,p_transaction:String(data.payload.id),p_event_at:eventAt?.toISOString()||null}),signal:AbortSignal.timeout(10000)});
   if(!stored.ok)return reply('Please retry notification',503);
   await processor(env,data,fetcher);
   return reply('Notification processed',200);
  }catch{return reply('Please retry notification',503)}
 };
}
