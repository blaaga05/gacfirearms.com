import {money} from './merch-cart.mjs?v=20261025-address-review';
const BASE='https://yuuagwxqhxiiybwjhome.supabase.co',KEY='sb_publishable_iYZBPKMeGQlAnst_uXBsRA_V0UL4z8L';
const STORAGE='gac-merch-orders-v1',el=(tag,text)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;return e};
export function merchandiseBreakdown(data){return[
 {label:'Items',amount:data.subtotal_cents},
 {label:data.tax_jurisdiction?data.tax_jurisdiction+' sales tax':'Sales tax',amount:data.tax_cents},
 {label:'Shipping',amount:data.shipping_cents},
 {label:'Total',amount:data.total_cents,total:true}
]}
export function mountMerchCheckout({button,getCart,getAccessToken,onPaid,onStockChanged}){
 let pending=null,pendingHosted=null,busy=false,current=null,polling=false,enabled=false;
 const cached=()=>{try{return JSON.parse(localStorage.getItem(STORAGE)||'[]')}catch{return[]}},remember=o=>{try{const safe={id:o.id,access:o.access};const rows=cached().filter(x=>x.id!==safe.id);localStorage.setItem(STORAGE,JSON.stringify([safe,...rows].slice(0,20)))}catch{}};
 const dialog=el('dialog');dialog.className='merch-cart merch-receipt';dialog.setAttribute('aria-labelledby','merchReceiptTitle');
 const title=el('h2','Your merchandise order');title.id='merchReceiptTitle';const info=el('p',''),lines=el('div'),message=el('p',''),refresh=el('button','Refresh payment status'),close=el('button','Continue shopping'),contact=el('a','Contact GAC');
 refresh.type=close.type='button';contact.href='mailto:info@gacfirearms.com';const actions=el('div');actions.className='merch-receipt-actions';refresh.className='ghost';contact.className='btn ghost';actions.append(close,refresh,contact);dialog.append(title,info,lines,message,actions);
 const style=el('style');style.textContent='.merch-receipt-actions{display:flex;flex-wrap:wrap;gap:12px;align-items:stretch;margin-top:24px}.merch-receipt-actions>button,.merch-receipt-actions>a{display:inline-flex;align-items:center;justify-content:center;margin:0;min-height:44px;padding:12px 18px;line-height:1.35;width:auto;white-space:normal;text-align:center}.merch-receipt h2{margin:0 0 20px;font-size:clamp(26px,4vw,36px)}@media(max-width:540px){.merch-receipt-actions{flex-direction:column}.merch-receipt-actions>button,.merch-receipt-actions>a{width:100%}}';
 document.head.append(style);document.body.append(dialog);let pollTimer;
 const deliveryDialog=el('dialog');deliveryDialog.className='merch-cart merch-delivery';deliveryDialog.setAttribute('aria-labelledby','merchDeliveryTitle');
 const deliveryTitle=el('h2','Delivery address');deliveryTitle.id='merchDeliveryTitle';
 const deliveryNote=el('p','Enter the delivery address. Tax is calculated from the verified delivery location.');
 const deliveryForm=el('form');deliveryForm.className='merch-delivery-form';
 const field=(labelText,id,type='text')=>{const label=el('label',labelText),input=type==='select'?el('select'):el('input');input.id=id;input.name=id;input.required=true;if(type!=='select')input.type=type;label.htmlFor=id;label.append(input);return{label,input}};
 const fullName=field('Full name','deliveryName'),address1=field('Street address','deliveryAddress1'),address2=field('Apartment, suite, etc. (optional)','deliveryAddress2'),city=field('City','deliveryCity'),state=field('State','deliveryState','select'),postal=field('ZIP code','deliveryPostal','text');
 address2.input.required=false;
 const states=[['AL','Alabama'],['AK','Alaska'],['AZ','Arizona'],['AR','Arkansas'],['CA','California'],['CO','Colorado'],['CT','Connecticut'],['DE','Delaware'],['DC','District of Columbia'],['FL','Florida'],['GA','Georgia'],['HI','Hawaii'],['ID','Idaho'],['IL','Illinois'],['IN','Indiana'],['IA','Iowa'],['KS','Kansas'],['KY','Kentucky'],['LA','Louisiana'],['ME','Maine'],['MD','Maryland'],['MA','Massachusetts'],['MI','Michigan'],['MN','Minnesota'],['MS','Mississippi'],['MO','Missouri'],['MT','Montana'],['NE','Nebraska'],['NV','Nevada'],['NH','New Hampshire'],['NJ','New Jersey'],['NM','New Mexico'],['NY','New York'],['NC','North Carolina'],['ND','North Dakota'],['OH','Ohio'],['OK','Oklahoma'],['OR','Oregon'],['PA','Pennsylvania'],['RI','Rhode Island'],['SC','South Carolina'],['SD','South Dakota'],['TN','Tennessee'],['TX','Texas'],['UT','Utah'],['VT','Vermont'],['VA','Virginia'],['WA','Washington'],['WV','West Virginia'],['WI','Wisconsin'],['WY','Wyoming']];
 const addOption=(select,value,label)=>{const option=el('option',label);option.value=value;select.append(option)};
 addOption(state.input,'','Choose state');for(const [code,name]of states)addOption(state.input,code,name);
 address1.input.autocomplete='shipping address-line1';address2.input.autocomplete='shipping address-line2';fullName.input.autocomplete='shipping name';city.input.autocomplete='shipping address-level2';state.input.autocomplete='shipping address-level1';postal.input.autocomplete='shipping postal-code';postal.input.inputMode='numeric';postal.input.pattern='[0-9]{5}(-[0-9]{4})?';postal.input.title='Enter a 5-digit ZIP code or ZIP+4.';
 const deliveryStatus=el('p','');deliveryStatus.setAttribute('role','status');const deliveryActions=el('div');deliveryActions.className='merch-receipt-actions';const deliveryCancel=el('button','Cancel'),deliveryContinue=el('button','Review order details');deliveryCancel.type=deliveryContinue.type='button';deliveryCancel.className='ghost';deliveryActions.append(deliveryCancel);deliveryContinue.type='submit';deliveryActions.append(deliveryContinue);deliveryForm.append(fullName.label,address1.label,address2.label,city.label,state.label,postal.label,deliveryStatus,deliveryActions);
 const reviewPanel=el('section');reviewPanel.className='merch-order-review';reviewPanel.hidden=true;reviewPanel.setAttribute('aria-labelledby','merchOrderReviewTitle');const reviewHeading=el('h3','Review order details');reviewHeading.id='merchOrderReviewTitle';const reviewAddress=el('p',''),reviewItems=el('div'),reviewRows=el('div'),reviewStatus=el('p','');reviewStatus.setAttribute('role','status');const reviewActions=el('div');reviewActions.className='merch-receipt-actions';const reviewEdit=el('button','Edit address'),reviewCancel=el('button','Cancel'),reviewPay=el('button','Continue to checkout');reviewEdit.type=reviewCancel.type=reviewPay.type='button';reviewEdit.className=reviewCancel.className='ghost';reviewPay.className='btn';reviewActions.append(reviewEdit,reviewCancel,reviewPay);reviewPanel.append(reviewHeading,reviewAddress,reviewItems,reviewRows,reviewStatus,reviewActions);deliveryDialog.append(deliveryTitle,deliveryNote,deliveryForm,reviewPanel);document.head.append(Object.assign(el('style'),{textContent:'.merch-order-review h3{margin:0 0 12px}.merch-review-line{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:4px 12px;padding:12px 0;border-bottom:1px solid rgba(190,210,190,.24)}.merch-review-line p{margin:0}.merch-review-line small{grid-column:1;color:inherit;opacity:.8}.merch-review-line strong{grid-column:2;grid-row:1 / span 2;align-self:center;white-space:nowrap}.merch-review-totals{margin-top:14px;border-top:1px solid rgba(190,210,190,.35);padding-top:10px}.merch-review-total{display:flex;justify-content:space-between;gap:16px;padding:5px 0}.merch-review-total.grand{font-weight:700;font-size:1.12em;padding-top:12px}' }));document.body.append(deliveryDialog);
 deliveryCancel.onclick=()=>deliveryDialog.close();
 deliveryForm.addEventListener('input',()=>{pending=null;pendingHosted=null;deliveryContinue.textContent='Review order details';deliveryStatus.textContent=''});
 reviewEdit.onclick=()=>{reviewPanel.hidden=true;deliveryForm.hidden=false;deliveryStatus.textContent='';fullName.input.focus()};reviewCancel.onclick=deliveryCancel.onclick=()=>deliveryDialog.close();
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
  lines.append(el('p','Subtotal '+money(d.subtotal_cents||0)+' · Tax '+money(d.tax_cents||0)+' · Shipping '+money(d.shipping_cents||0)+' · Total '+money(d.total_cents||0)));
  message.textContent=d.note||labels[d.state]||'Contact GAC about this order.';
  if(!dialog.open)dialog.showModal();
  if(d.state==='paid'&&!o.applied){o.applied=true;remember(o);onPaid?.(d.lines||[]);}
  onStockChanged?.();
 }
 async function check(){if(!current||polling||document.hidden)return;polling=true;try{const d=await call({action:'status',id:current.id,access:current.access});show(current,d);if(['paid','voided','declined','cancelled','refunded','partially_refunded'].includes(d.state))clearInterval(pollTimer)}catch(e){message.textContent=e.message;if(!dialog.open)dialog.showModal()}finally{polling=false}}
 refresh.onclick=check;
 button.onclick=()=>{if(!busy&&enabled&&getCart().length)deliveryDialog.showModal()};
 function renderReview(data,shipping){
  reviewAddress.textContent='Deliver to: '+[shipping.name,shipping.address1,shipping.address2,shipping.city+', '+shipping.state+' '+shipping.postal_code].filter(Boolean).join(', ');
  reviewItems.replaceChildren();for(const line of data.lines||[]){const row=el('div');row.className='merch-review-line';row.append(el('p',line.name));row.append(el('small',line.size+' · '+line.quantity+' × '+money(line.unit_cents)));row.append(el('strong',money(line.unit_cents*line.quantity)));reviewItems.append(row)}
  reviewRows.replaceChildren();reviewRows.className='merch-review-totals';for(const item of merchandiseBreakdown(data)){const row=el('div');row.className='merch-review-total'+(item.total?' grand':'');row.append(el('span',item.label),el('strong',money(item.amount||0)));reviewRows.append(row)}
  reviewStatus.textContent='Stock is held for 20 minutes while you complete checkout.';deliveryForm.hidden=true;reviewPanel.hidden=false;reviewPay.disabled=false;reviewPay.focus();
 }
 function continueToPayment(){const d=pendingHosted?.data;if(!d){reviewStatus.textContent='Review the order again before continuing.';reviewPanel.hidden=true;deliveryForm.hidden=false;return;}const expected=d.environment==='sandbox'?'https://test.authorize.net/payment/payment':'https://accept.authorize.net/payment/payment';if(d.url!==expected||typeof d.token!=='string'||d.token.length<10){reviewStatus.textContent='Invalid payment destination. Please start again.';return;}const form=el('form');form.method='POST';form.action=d.url;form.enctype='application/x-www-form-urlencoded';form.target='_self';form.style.display='none';const token=el('input');token.type='hidden';token.name='token';token.value=d.token;form.append(token);document.body.append(form);form.submit()}
 reviewPay.onclick=continueToPayment;
 deliveryForm.onsubmit=async event=>{
  event.preventDefault();if(busy||!enabled)return;const cart=getCart(),shipping={name:fullName.input.value.trim(),address1:address1.input.value.trim(),address2:address2.input.value.trim(),city:city.input.value.trim(),state:state.input.value,postal_code:postal.input.value.trim(),country:'US'},signature=JSON.stringify([cart,shipping]);
  if(pendingHosted?.signature===signature){renderReview(pendingHosted.data,shipping);return;}
  busy=true;updateButton();deliveryContinue.disabled=true;deliveryStatus.textContent='Verifying delivery location and preparing your order…';
  try{
   if(!cart.length)throw Error('Add an item first.');
   if(!pending||pending.signature!==signature){const access=[...crypto.getRandomValues(new Uint8Array(32))].map(n=>n.toString(16).padStart(2,'0')).join('');pending={id:crypto.randomUUID(),access,signature};}
   const d=await call({action:'start',id:pending.id,access:pending.access,cart,shipping});remember(pending);
   if(!Number.isInteger(d.total_cents)||!Number.isInteger(d.subtotal_cents)||!Number.isInteger(d.shipping_cents)||!Number.isInteger(d.tax_cents))throw Error('The final order total could not be verified.');
   pendingHosted={signature,data:d};renderReview(d,shipping);
  }catch(e){deliveryStatus.textContent=e.message;deliveryContinue.disabled=false;deliveryContinue.textContent='Review order details'}
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
