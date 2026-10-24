import {money} from './merch-cart.mjs?v=20261017-stock';
const BASE='https://egrsgfukkramgbibqsbx.supabase.co',KEY='sb_publishable_Vttu1L2cnuQhkrJw0V4rvA_ax4k1S7H';
const STORAGE='gac-merch-orders-v1',el=(tag,text)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;return e};
export function mountMerchCheckout({button,getCart,getAccessToken,onPaid,onStockChanged}){
 let pending=null,busy=false,current=null,polling=false,enabled=false;
 const cached=()=>{try{return JSON.parse(localStorage.getItem(STORAGE)||'[]')}catch{return[]}},remember=o=>{try{const rows=cached().filter(x=>x.id!==o.id);localStorage.setItem(STORAGE,JSON.stringify([o,...rows].slice(0,20)))}catch{}};
 const dialog=el('dialog');dialog.className='merch-cart merch-receipt';dialog.setAttribute('aria-labelledby','merchReceiptTitle');
 const title=el('h2','Your merchandise order');title.id='merchReceiptTitle';const info=el('p',''),lines=el('div'),message=el('p',''),refresh=el('button','Refresh payment status'),close=el('button','Continue shopping'),contact=el('a','Contact GAC');
 refresh.type=close.type='button';contact.href='mailto:info@gacfirearms.com';const actions=el('div');actions.className='merch-receipt-actions';refresh.className='ghost';contact.className='btn ghost';actions.append(close,refresh,contact);dialog.append(title,info,lines,message,actions);
 const style=el('style');style.textContent='.merch-receipt-actions{display:flex;flex-wrap:wrap;gap:12px;align-items:stretch;margin-top:24px}.merch-receipt-actions>button,.merch-receipt-actions>a{display:inline-flex;align-items:center;justify-content:center;margin:0;min-height:44px;padding:12px 18px;line-height:1.35;width:auto;white-space:normal;text-align:center}.merch-receipt h2{margin:0 0 20px;font-size:clamp(26px,4vw,36px)}@media(max-width:540px){.merch-receipt-actions{flex-direction:column}.merch-receipt-actions>button,.merch-receipt-actions>a{width:100%}}';
 document.head.append(style);document.body.append(dialog);let pollTimer;
 close.onclick=()=>{dialog.close();clearInterval(pollTimer)};
 async function call(body){
  const headers={apikey:KEY,'Content-Type':'application/json'};if(body.action==='start'&&getAccessToken){const token=await getAccessToken();if(token)headers.Authorization='Bearer '+token;}
  const r=await fetch(BASE+'/functions/v1/gac-merch-checkout',{method:'POST',headers,body:JSON.stringify(body),signal:AbortSignal.timeout(30000),cache:'no-store'});
  const d=await r.json().catch(()=>({}));if(!r.ok||d.error)throw Error(d.error||'Checkout unavailable');return d;
 }
 function updateButton(){button.textContent='Checkout';button.disabled=!enabled||busy||!getCart().length;button.title=enabled?'Continue to secure hosted checkout':'Paid merchandise checkout is unavailable while GAC completes its release checks.'}
 function show(o,d){
  const labels={pending:'Payment has not been confirmed. Stock is temporarily held until '+new Date(d.expires_at).toLocaleTimeString()+'. If you already submitted payment, do not pay again.',expired:'The checkout hold expired. If you paid, contact GAC before starting another checkout.',paid:'Payment verified. GAC will contact you about fulfillment.',declined:'Payment was declined. No merchandise was fulfilled.',voided:'The payment was voided. Contact GAC if you have questions.',review:'Payment needs GAC review. Do not pay again.',refund_pending:'Your refund is pending settlement.',partially_refunded:'A partial refund has been recorded.',refunded:'The payment has been refunded.',cancelled:'This checkout was cancelled.'};
  title.textContent=d.state==='paid'?'Payment verified — thank you!':d.state==='review'?'Your payment needs GAC review':'Your merchandise order';
  info.textContent='Order '+o.id.slice(0,8)+' · '+money(d.total_cents||0)+' · '+String(d.state||'pending').replaceAll('_',' ');
  lines.replaceChildren();
  for(const l of d.lines||[])lines.append(el('p',l.name+' · '+l.size+' × '+l.quantity+' · '+money(l.unit_cents*l.quantity)));
  lines.append(el('p','Subtotal '+money(d.subtotal_cents||0)+' · Shipping '+money(d.shipping_cents||0)+' · Tax '+money(d.tax_cents||0)));
  message.textContent=d.note||labels[d.state]||'Contact GAC about this order.';
  if(!dialog.open)dialog.showModal();
  if(d.state==='paid'&&!o.applied){o.applied=true;remember(o);onPaid?.(d.lines||[]);}
  onStockChanged?.();
 }
 async function check(){if(!current||polling||document.hidden)return;polling=true;try{const d=await call({action:'status',id:current.id,access:current.access});show(current,d);if(['paid','voided','declined','cancelled','refunded','partially_refunded'].includes(d.state))clearInterval(pollTimer)}catch(e){message.textContent=e.message;if(!dialog.open)dialog.showModal()}finally{polling=false}}
 refresh.onclick=check;
 button.onclick=async()=>{
  if(busy||!enabled)return;busy=true;updateButton();const cart=getCart(),signature=JSON.stringify(cart);
  try{
   if(!cart.length)throw Error('Add an item first.');
   if(!pending||pending.signature!==signature){const access=[...crypto.getRandomValues(new Uint8Array(32))].map(n=>n.toString(16).padStart(2,'0')).join('');pending={id:crypto.randomUUID(),access,signature};}
   remember(pending);const d=await call({action:'start',id:pending.id,access:pending.access,cart});
   const expected=d.environment==='sandbox'?'https://test.authorize.net/payment/payment':'https://accept.authorize.net/payment/payment';
   if(d.url!==expected||typeof d.token!=='string'||d.token.length<10)throw Error('Invalid payment destination.');
   const form=el('form');form.method='POST';form.action=d.url;form.enctype='application/x-www-form-urlencoded';form.target='_self';form.style.display='none';
   const token=el('input');token.type='hidden';token.name='token';token.value=d.token;form.append(token);document.body.append(form);form.submit();
  }catch(e){message.textContent=e.message;if(!dialog.open)dialog.showModal()}
  finally{busy=false;updateButton()}
 };
 async function loadAvailability(){
  try{const d=await call({action:'availability'});enabled=d.enabled===true;button.parentElement?.querySelector('[data-checkout-note]')?.remove();const note=el('p',enabled?'Shipping and tax are calculated before payment. Stock is held only after checkout begins.':'Online checkout is being prepared. No payment can be accepted yet.');note.dataset.checkoutNote='';note.className='cart-disclaimer';button.parentElement?.append(note)}
  catch{enabled=false}
  updateButton();
 }
 const recent=el('button','View recent merchandise order');recent.type='button';recent.className='ghost';button.parentElement.after(recent);
 recent.onclick=()=>{current=cached()[0];if(current)check();else{message.textContent='No checkout has been started in this browser.';dialog.showModal()}};
 const query=new URLSearchParams(location.search),id=query.get('merch_order'),returned=query.has('merch_return');
 if(id||returned){current=id?cached().find(o=>o.id===id):cached()[0];query.delete('merch_order');query.delete('merch_return');query.delete('cancelled');history.replaceState(null,'',location.pathname+(query.size?'?'+query:'')+location.hash);if(current){check();pollTimer=setInterval(check,5000)}else{message.textContent='Open the order in the browser where checkout began, or contact GAC. Returning here does not confirm payment.';dialog.showModal()}}
 void loadAvailability();
 return {update:updateButton};
}
