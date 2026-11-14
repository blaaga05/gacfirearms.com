import {formatOrderReference} from './order-reference.mjs?v=20261028-ak-reference';
const money=cents=>new Intl.NumberFormat("en-US",{style:"currency",currency:"USD"}).format(cents/100);
const text=(tag,value)=>{const e=document.createElement(tag);e.textContent=value;return e};
const STATUS_LABELS={pending_fulfillment:"Paid · awaiting fulfillment",processing:"Processing",shipped:"Shipped",delivered:"Delivered",cancelled:"Cancelled"};
const CARRIERS=["","USPS","UPS","FedEx","DHL","Other"];
const field=(parent,labelText,control)=>{const wrap=document.createElement("label");wrap.textContent=labelText;wrap.append(control);parent.append(wrap);return control};

export function mountStoreOrdersAdmin({client,addAdmin,action,status,onNewOrders=()=>{}}){
 const panel=addAdmin("storeOrders","Order oversight",'<div class="card"><div class="top"><div><h2>Order oversight · merchandise</h2><p>Review payment holds, update fulfillment status, and add carrier and tracking details. Firearm order requests remain in their own section.</p></div><button id="storeOrdersRefresh" type="button" class="secondary">Refresh orders</button></div><div id="storeOrdersStatus" role="status" aria-live="polite"></div><div id="merchCheckoutReviews"></div><div id="storeOrdersList"></div></div>');
 const $=id=>panel.querySelector("#"+id);
 let owner=false,orders=[],reviewOrders=[],epoch=0;
 async function load(){
  if(!owner)return;const version=epoch;
  $("storeOrdersStatus").textContent="Loading orders…";
  const [ordersResult,reviewsResult]=await Promise.all([client.from("gac_store_orders").select("*").order("created_at",{ascending:false}),client.rpc("gac_owner_merch_orders")]);
  if(ordersResult.error)throw ordersResult.error;if(reviewsResult.error)throw reviewsResult.error;if(!owner||version!==epoch)return;
  orders=ordersResult.data||[];reviewOrders=(reviewsResult.data||[]).filter(order=>["review","refund_pending","partially_refunded"].includes(order.state));onNewOrders(orders.filter(order=>order.fulfillment_status==="pending_fulfillment").length+reviewOrders.length);render();$("storeOrdersStatus").textContent="";
 }
 function render(){
  const reviewHost=$("merchCheckoutReviews");reviewHost.replaceChildren();const reviewHeading=text("h3","Payment review holds");reviewHost.append(reviewHeading);
  if(!reviewOrders.length)reviewHost.append(text("p","No merchandise payment reviews need attention."));
  for(const order of reviewOrders){const details=document.createElement("details");details.className="editable-member";const summary=text("summary",order.invoice+" · "+(order.state||"review").replaceAll("_"," ")+" · "+money(order.total_cents));const body=document.createElement("div");body.style.cssText="display:grid;gap:8px;margin-top:12px";const lines=(Array.isArray(order.lines)?order.lines:[]).map(item=>[item.name,item.size&&"Size "+item.size,item.quantity&&"Qty "+item.quantity].filter(Boolean).join(" · ")).join(" | ");body.append(text("p","Created "+new Date(order.created_at).toLocaleString()+" · "+lines));if(order.email)body.append(text("p","Customer: "+order.email));if(order.note)body.append(text("p","GAC note: "+order.note));body.append(text("p","Stock remains reserved. Verify the payment in Authorize.Net and contact the customer before resolving this order."));details.append(summary,body);reviewHost.append(details)}
  const host=$("storeOrdersList");host.replaceChildren();
  if(!orders.length){host.append(text("p","No merchandise checkout orders yet. This list will fill after main-site checkout is connected."));return;}
  for(const order of orders){
   const details=document.createElement("details");details.className="editable-member";
   const summary=text("summary","Order "+formatOrderReference(order)+" · "+order.customer_email+" · "+(STATUS_LABELS[order.fulfillment_status]||order.fulfillment_status)+" · "+money(order.total_cents));
   const body=document.createElement("div");body.style.cssText="display:grid;gap:10px;margin-top:16px";
   const itemSummary=(Array.isArray(order.items)?order.items:[]).map(item=>[item.name,item.size&&"Size "+item.size,item.quantity&&"Qty "+item.quantity].filter(Boolean).join(" · ")).join(" | ");
   body.append(text("p","Placed "+new Date(order.created_at).toLocaleString()+" · "+itemSummary));
   const address=order.shipping_address||{},addressText=[address.name,address.address1,address.address2,[address.city,address.state,address.postal_code].filter(Boolean).join(", "),address.country].filter(Boolean).join(" · ");
   body.append(text("p","Ship to: "+(addressText||"No shipping address recorded.")));
   const statusSelect=document.createElement("select");
   for(const [value,label] of Object.entries(STATUS_LABELS)){const o=text("option",label);o.value=value;statusSelect.append(o);}
   statusSelect.value=order.fulfillment_status;
   const carrier=document.createElement("select");
   for(const value of CARRIERS){const o=text("option",value||"Select carrier");o.value=value;carrier.append(o);}
   carrier.value=order.carrier||"";
   const tracking=document.createElement("input");tracking.type="text";tracking.maxLength=120;tracking.value=order.tracking_number||"";tracking.placeholder="Tracking number";
   const trackingUrl=document.createElement("input");trackingUrl.type="url";trackingUrl.maxLength=1000;trackingUrl.value=order.tracking_url||"";trackingUrl.placeholder="https:// carrier tracking link";
   const fields=document.createElement("div");fields.className="grid";fields.style.cssText="grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:12px";
   field(fields,"Fulfillment status",statusSelect);field(fields,"Carrier",carrier);field(fields,"Tracking number",tracking);field(fields,"Tracking link",trackingUrl);
   const save=text("button","Save fulfillment update");save.type="button";save.className="secondary";
   save.onclick=()=>action(async()=>{
    const url=trackingUrl.value.trim();
    if(url&&!/^https:\/\//i.test(url))throw Error("Tracking link must start with https://");
    const nextStatus=statusSelect.value,now=new Date().toISOString(),userResult=await client.auth.getUser();
    const patch={fulfillment_status:nextStatus,carrier:carrier.value||null,tracking_number:tracking.value.trim()||null,tracking_url:url||null,shipped_at:nextStatus==="shipped"||nextStatus==="delivered"?(order.shipped_at||now):null,delivered_at:nextStatus==="delivered"?(order.delivered_at||now):null,updated_at:now,updated_by:userResult.data?.user?.id||null};
    const {error}=await client.from("gac_store_orders").update(patch).eq("id",order.id);
    if(error)throw error;
    await load();status("Order "+formatOrderReference(order)+" updated.");
   });
   body.append(fields,save);details.append(summary,body);host.append(details);
  }
 }
 $("storeOrdersRefresh").onclick=()=>action(load);
 async function refreshIndicator(){if(!owner)return;const version=epoch,[ordersResult,reviewsResult]=await Promise.all([client.from("gac_store_orders").select("fulfillment_status"),client.rpc("gac_owner_merch_orders")]);if(ordersResult.error)throw ordersResult.error;if(reviewsResult.error)throw reviewsResult.error;if(!owner||version!==epoch)return;onNewOrders((ordersResult.data||[]).filter(order=>order.fulfillment_status==="pending_fulfillment").length+(reviewsResult.data||[]).filter(order=>["review","refund_pending","partially_refunded"].includes(order.state)).length);}
 return {sync(isOwner){const next=!!isOwner;if(owner!==next){owner=next;epoch++;}return owner?load():Promise.resolve();},refreshIndicator,clear(){owner=false;epoch++;onNewOrders(0);orders=[];reviewOrders=[];$("storeOrdersList").replaceChildren();$("merchCheckoutReviews").replaceChildren();$("storeOrdersStatus").textContent="";}};
}
