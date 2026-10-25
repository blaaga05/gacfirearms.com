const clean=(value,max)=>String(value||'').trim().replace(/[\u0000-\u001f\u007f]/g,'').slice(0,max);

export function createAddressSuggestionsHandler({env,fetcher=fetch}){
 return async req=>{
  const origin=req.headers.get('origin'),configuredOrigin=env('GAC_SITE_ORIGIN')||'https://payment-sandbox.gacfirearms-com.pages.dev',allowedOrigins=new Set([configuredOrigin,'https://payment-sandbox.gacfirearms-com.pages.dev']);
  const headers={'Content-Type':'application/json','Cache-Control':'no-store','Access-Control-Allow-Headers':'apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS','Vary':'Origin'};
  const reply=(body,status=200)=>new Response(JSON.stringify(body),{status,headers:{...headers,'Access-Control-Allow-Origin':origin&&allowedOrigins.has(origin)?origin:configuredOrigin}});
  if(!origin||!allowedOrigins.has(origin))return reply({error:'Origin not allowed'},403);
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers:{...headers,'Access-Control-Allow-Origin':origin}});
  if(req.method!=='POST')return reply({error:'POST required'},405);
  try{
   const text=await req.text();if(text.length>500)return reply({error:'Search text is too long'},413);
   let body;try{body=JSON.parse(text)}catch{return reply({error:'Invalid request'},400)}
   const query=clean(body.query,120);if(query.length<4)return reply({suggestions:[]});
   const apiKey=env('GEOAPIFY_API_KEY');if(!apiKey)return reply({error:'Address suggestions are not configured yet.'},503);
   const url=new URL('https://api.geoapify.com/v1/geocode/autocomplete');url.searchParams.set('text',query);url.searchParams.set('format','json');url.searchParams.set('limit','5');url.searchParams.set('filter','countrycode:us');url.searchParams.set('apiKey',apiKey);
   const response=await fetcher(url,{signal:AbortSignal.timeout(8000),headers:{Accept:'application/json'}});if(!response.ok)return reply({error:'Address suggestions are temporarily unavailable.'},503);
   const payload=await response.json();const suggestions=(payload.results||[]).filter(x=>String(x.country_code||'').toLowerCase()==='us').map(x=>({country_code:x.country_code,address_line1:[x.housenumber,x.street].filter(Boolean).join(' ')||x.address_line1,street:x.street,housenumber:x.housenumber,city:x.city||x.town||x.village||x.municipality,state:x.state,state_code:x.state_code,postcode:x.postcode,formatted:x.formatted})).filter(x=>x.address_line1).slice(0,5);
   return reply({suggestions});
  }catch{return reply({error:'Address suggestions are temporarily unavailable.'},503)}
 };
}
