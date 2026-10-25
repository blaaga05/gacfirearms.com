import test from 'node:test';
import assert from 'node:assert/strict';
import {createMerchHandler,merchandiseSettings,validateMerchShipping,hash} from '../supabase/functions/gac-merch-checkout/handler.mjs';
import {merchandiseBreakdown} from '../merch-checkout.mjs';
import {observeTransaction} from '../supabase/functions/gac-payment-recovery/handler.mjs';

const id='11111111-1111-4111-8111-111111111111';
const access='a'.repeat(64);
const address={name:'Blake Gassett',address1:'123 Main St',address2:'',city:'Kathleen',state:'GA',postal_code:'31047',country:'US'};
const lines=[{id:'97bc4ced-adb1-462a-ac3f-f4f524e08b10',name:'GAC Built for Purpose Tee',size:'S',quantity:1,unit_cents:3000,image_path:'/assets/gac-shirt.png'}];
const settings={AUTHORIZENET_ENVIRONMENT:'sandbox',AUTHORIZENET_SANDBOX_PROJECT_URL:'https://test.supabase.co',SUPABASE_URL:'https://test.supabase.co',SUPABASE_SERVICE_ROLE_KEY:'fixture',SUPABASE_ANON_KEY:'fixture-publishable',GAC_SITE_ORIGIN:'https://test.example.invalid',AUTHORIZENET_SANDBOX_API_LOGIN_ID:'fixture-login',AUTHORIZENET_SANDBOX_TRANSACTION_KEY:'fixture-key'};
const env=k=>settings[k],json=x=>new Response(JSON.stringify(x));
const census=()=>json({result:{addressMatches:[{matchedAddress:'123 MAIN ST, KATHLEEN, GA, 31047',coordinates:{x:-83.6,y:32.5},geographies:{States:[{STUSAB:'GA',NAME:'Georgia'}],Counties:[{BASENAME:'Houston',NAME:'Houston County, Georgia'}],'Incorporated Places':[]}}]}});
const request=b=>new Request('https://test.example.invalid/checkout',{method:'POST',headers:{origin:'https://test.example.invalid','content-type':'application/json'},body:JSON.stringify({shipping:address,...b})});
const session=()=>({token:null,lines,subtotal_cents:3000,shipping_cents:0,tax_cents:240,tax_rate_bps:800,tax_jurisdiction:'Houston',total_cents:3240,expires_at:'2026-10-18T02:00:00Z'});
const censusRequest=url=>String(url).startsWith('https://geocoding.geo.census.gov')?census():null;

test('order review puts calculated tax above the saved shipping charge and includes it in total',()=>{
 const rows=merchandiseBreakdown({subtotal_cents:3000,tax_cents:240,tax_jurisdiction:'Houston',shipping_cents:895,total_cents:4135});
 assert.deepEqual(rows.map(row=>row.label),['Items','Houston sales tax','Shipping','Total']);
 assert.equal(rows[2].amount,895);assert.equal(rows[3].amount,4135);
});

test('guest checkout resolves tax from address and sends the itemized total to Accept Hosted',async()=>{
 let charge,begin;const h=createMerchHandler({env,fetcher:async(url,o)=>{
  const geocoder=censusRequest(url);if(geocoder)return geocoder;
  if(String(url).endsWith('/webhooks'))return json([{url:'https://test.supabase.co/functions/v1/gac-authorizenet-webhook',status:'active',eventTypes:['net.authorize.payment.authcapture.created']}]);
  const b=JSON.parse(o.body);
  if(String(url).endsWith('gac_begin_merch_checkout')){begin=b;assert.equal(b.p_cart[0].amount,undefined);return json({id,invoice:'GAM0123456789abcdef0',subtotal_cents:3000,shipping_cents:0,tax_cents:240,tax_rate_bps:800,tax_jurisdiction:'Houston',total_cents:3240,expires_at:'2026-10-18T02:00:00Z'})}
  if(String(url).endsWith('gac_merch_order_session'))return json(session());
  if(String(url).includes('apitest.authorize.net')){charge=b.getHostedPaymentPageRequest;return json({messages:{resultCode:'Ok'},token:'fixture-payment-token'})}
  throw Error(url);
 }});
 const r=await h(request({action:'start',id,access,amount:1,cart:[{id,size:'S',quantity:1,amount:1}]}));const d=await r.json();
 assert.equal(r.status,200);assert.equal(begin.p_tax_bps,800);assert.equal(begin.p_shipping.county,'Houston');assert.equal(begin.p_shipping.district,'county');assert.equal(charge.transactionRequest.amount,'32.40');assert.equal(charge.transactionRequest.payment,undefined);assert.equal(charge.transactionRequest.shipTo.city,'Kathleen');
 assert.deepEqual(charge.transactionRequest.lineItems.lineItem,[{itemId:'97bc4cedadb1462aac3ff4f524e1',name:'GAC Built for Purpose Tee',description:'Size S',quantity:'1',unitPrice:'30.00'}]);
 assert.deepEqual(charge.transactionRequest.tax,{amount:'2.40',name:'Sales tax',description:'Houston sales tax'});assert.equal(charge.transactionRequest.shipping,undefined);assert.equal(d.lines[0].name,'GAC Built for Purpose Tee');
 assert.equal(d.environment,'sandbox');assert.equal(d.url,'https://test.authorize.net/payment/payment');const hosted=Object.fromEntries(charge.hostedPaymentSettings.setting.map(x=>[x.settingName,JSON.parse(x.settingValue)]));assert.equal(hosted.hostedPaymentShippingAddressOptions.required,false);assert.equal(hosted.hostedPaymentShippingAddressOptions.show,false);assert.equal(hosted.hostedPaymentCustomerOptions.addPaymentProfile,false);assert.equal(hosted.hostedPaymentReturnOptions.url,'https://test.example.invalid/merch-return.html?order='+id);assert.equal(hosted.hostedPaymentReturnOptions.cancelUrl,'https://test.example.invalid/merch-cancel.html?order='+id);assert.ok(!JSON.stringify(d).includes('fixture-key'));
});

test('signed-in merchandise checkout links the verified Supabase member to their order',async()=>{
 let attached=false;const h=createMerchHandler({env,fetcher:async(url,o)=>{
  const geocoder=censusRequest(url);if(geocoder)return geocoder;
  if(String(url).endsWith('/webhooks'))return json([{url:'https://test.supabase.co/functions/v1/gac-authorizenet-webhook',status:'active',eventTypes:['net.authorize.payment.authcapture.created']}]);
  if(String(url).endsWith('/auth/v1/user')){assert.equal(o.headers.Authorization,'Bearer member-session');return json({id:'22222222-2222-4222-8222-222222222222'})}
  if(String(url).endsWith('gac_begin_merch_checkout'))return json({id,invoice:'GAM0123456789abcdef0',subtotal_cents:3000,shipping_cents:0,tax_cents:240,total_cents:3240,expires_at:'2026-10-18T02:00:00Z'});
  if(String(url).endsWith('gac_attach_merch_customer')){attached=true;assert.deepEqual(JSON.parse(o.body),{p_id:id,p_access_hash:await hash(access),p_user_id:'22222222-2222-4222-8222-222222222222'});return json(null)}
  if(String(url).endsWith('gac_merch_order_session'))return json(session());
  if(String(url).includes('apitest.authorize.net'))return json({messages:{resultCode:'Ok'},token:'fixture-payment-token'});
  throw Error(url);
 }});
 const req=new Request('https://test.example.invalid/checkout',{method:'POST',headers:{origin:'https://test.example.invalid','content-type':'application/json',authorization:'Bearer member-session'},body:JSON.stringify({shipping:address,action:'start',id,access,cart:[{id,size:'S',quantity:1}]})});const r=await h(req);assert.equal(r.status,200,JSON.stringify(await r.clone().json()));assert.ok(attached);
});

test('production merchandise payment creation is blocked before any gateway call',async()=>{let calls=0;const h=createMerchHandler({env:k=>k==='AUTHORIZENET_ENVIRONMENT'?'production':env(k),fetcher:async()=>{calls++;throw Error('Unexpected')}});const r=await h(request({action:'start',id,access,cart:[]}));assert.equal(r.status,409);assert.equal(calls,0)});
test('production checkout availability stays closed before any database or gateway call',async()=>{let calls=0;const h=createMerchHandler({env:k=>k==='AUTHORIZENET_ENVIRONMENT'?'production':env(k),fetcher:async()=>{calls++;throw Error('Unexpected')}});const r=await h(request({action:'availability'}));assert.equal(r.status,200);assert.deepEqual(await r.json(),{enabled:false});assert.equal(calls,0)});
test('turning off new production checkout does not block checking an existing order',async()=>{let called=false;const h=createMerchHandler({env:k=>k==='AUTHORIZENET_ENVIRONMENT'?'production':env(k),fetcher:async url=>{called=true;assert.ok(String(url).endsWith('/gac_merch_order_session'));return json({state:'pending',token:'secret-token',total_cents:100})}});const r=await h(request({action:'status',id,access}));assert.equal(r.status,200);assert.equal((await r.json()).state,'pending');assert.ok(called)});
test('order status never returns a hosted token or proves payment from the return URL',async()=>{const h=createMerchHandler({env,fetcher:async()=>json({state:'pending',token:'secret-token',total_cents:100})});const r=await h(request({action:'status',id,access,paid:true}));const d=await r.json();assert.equal(d.state,'pending');assert.equal(d.token,undefined)});

test('canonical payment fulfillment preserves server tax location and never stores card data',async()=>{let args;const r=await observeTransaction(env,{transId:'98767001',transactionType:'authCaptureTransaction',transactionStatus:'capturedPendingSettlement',responseCode:1,settleAmount:'32.40',submitTimeUTC:'2026-10-18T01:00:00Z',order:{invoiceNumber:'GAM0123456789abcdef0'},customer:{email:'test@example.invalid'},shipTo:{firstName:'Test',lastName:'Buyer',address:'123 Test St',city:'Kathleen',state:'GA',zip:'31047',country:'USA',cardNumber:'must-not-store'},payment:{cardNumber:'must-not-store'}},async(url,o)=>{if(String(url).endsWith('gac_merch_shipping_for_invoice'))return json({...address,county:'Houston',tax_rate_bps:800,tax_jurisdiction:'Houston'});assert.ok(String(url).endsWith('gac_apply_merch_gateway'));args=JSON.parse(o.body);return json('credited')});assert.equal(r.outcome,'credited');assert.equal(args.p_amount_cents,3240);assert.equal(args.p_shipping.address1,'123 Main St');assert.equal(args.p_shipping.county,'Houston');assert.equal(args.p_shipping.tax_rate_bps,800);assert.equal(args.p_email,'test@example.invalid');assert.equal(args.p_shipping.cardNumber,undefined);assert.ok(!JSON.stringify(args).includes('must-not-store'))});

test('address validation no longer accepts customer-selected tax jurisdictions',()=>{
 const result=validateMerchShipping({...address,county:'Fulton',district:'Atlanta'});assert.equal(result.shipping.county,undefined);assert.equal(result.shipping.district,undefined);
 assert.throws(()=>validateMerchShipping({...address,state:'ZZ'}),/complete US/);assert.throws(()=>validateMerchShipping({...address,postal_code:'invalid'}),/complete US/);
 assert.equal(validateMerchShipping({...address,state:'FL'}).shipping.state,'FL');
});
