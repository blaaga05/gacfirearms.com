const clean=(value,max)=>String(value||'').trim().replace(/[\u0000-\u001f\u007f]/g,'').slice(0,max);
const stateCodes=new Set('AL AK AZ AR CA CO CT DE DC FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY'.split(' '));
const stateNames=['Alabama','Alaska','Arizona','Arkansas','California','Colorado','Connecticut','Delaware','District of Columbia','Florida','Georgia','Hawaii','Idaho','Illinois','Indiana','Iowa','Kansas','Kentucky','Louisiana','Maine','Maryland','Massachusetts','Michigan','Minnesota','Mississippi','Missouri','Montana','Nebraska','Nevada','New Hampshire','New Jersey','New Mexico','New York','North Carolina','North Dakota','Ohio','Oklahoma','Oregon','Pennsylvania','Rhode Island','South Carolina','South Dakota','Tennessee','Texas','Utah','Vermont','Virginia','Washington','West Virginia','Wisconsin','Wyoming'];
function typedCity(query){
 const parts=String(query||'').split(',').map(part=>part.trim()).filter(Boolean);if(parts.length<2)return '';
 let tail=parts.at(-1).replace(/\b\d{5}(?:-\d{4})?\b/g,'').trim();
 const code=tail.match(/\b([A-Z]{2})$/i);
 if(code&&stateCodes.has(code[1].toUpperCase())){tail=tail.slice(0,code.index).trim();return tail||parts.at(-2)||''}
 const name=stateNames.find(value=>new RegExp(`(?:^|\\s)${value.replaceAll(' ','\\s+')}\\s*$`,'i').test(tail));
 if(name){tail=tail.replace(new RegExp(`(?:^|\\s)${name.replaceAll(' ','\\s+')}\\s*$`,'i'),'').trim();return tail||parts.at(-2)||''}
 return tail;
}

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
   const url=new URL('https://api.geoapify.com/v1/geocode/autocomplete');url.searchParams.set('text',query);url.searchParams.set('type','street');url.searchParams.set('format','json');url.searchParams.set('limit','10');url.searchParams.set('filter','countrycode:us');url.searchParams.set('apiKey',apiKey);
   const response=await fetcher(url,{signal:AbortSignal.timeout(8000),headers:{Accept:'application/json'}});if(!response.ok)return reply({error:'Address suggestions are temporarily unavailable.'},503);
   const payload=await response.json(),suggestions=[],seen=new Set();
   for(const x of payload.results||[]){
    if(String(x.country_code||'').toLowerCase()!=='us'||!['building','street'].includes(String(x.result_type||'').toLowerCase())||!String(x.street||'').trim())continue;
    const city=typedCity(query)||x.city||x.town||x.village||x.municipality;
    const suggestion={country_code:x.country_code,address_line1:[x.housenumber,x.street].filter(Boolean).join(' ')||x.address_line1,street:x.street,housenumber:x.housenumber,city,state:x.state,state_code:x.state_code,postcode:x.postcode,formatted:[ [x.housenumber,x.street].filter(Boolean).join(' ')||x.address_line1,city,x.state_code||x.state,x.postcode].filter(Boolean).join(', ')};
    if(!suggestion.address_line1)continue;
    const identity=[suggestion.address_line1,suggestion.city,suggestion.state_code||suggestion.state,suggestion.postcode].map(v=>String(v||'').trim().toLowerCase()).join('|');
    if(seen.has(identity))continue;seen.add(identity);suggestions.push(suggestion);if(suggestions.length===5)break;
   }
   return reply({suggestions});
  }catch{return reply({error:'Address suggestions are temporarily unavailable.'},503)}
 };
}
