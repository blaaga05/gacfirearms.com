const money=cents=>new Intl.NumberFormat("en-US",{style:"currency",currency:"USD"}).format(cents/100);
const text=(tag,value)=>{const e=document.createElement(tag);e.textContent=value;return e};
const STATUS_LABELS={pending_fulfillment:"Paid · awaiting fulfillment",processing:"Processing",shipped:"Shipped",delivered:"Delivered",cancelled:"Cancelled"};
const CARRIERS=["","USPS","UPS","FedEx","DHL","Other"];
const field=(parent,labelText,control)=>{const wrap=document.createElement("label");wrap.textContent=labelText;wrap.append(control);parent.append(wrap);return control};

export function mountStoreOrdersAdmin({client,addAdmin,action,status,onNewOrders=()=>{}}){
 const panel=addAdmin("storeOrders","Order oversight",'<div class="card"><div class="top"><div><h2>Order oversight · merchandise</h2><p>Update fulfillment status and add carrier and tracking details. Digital-logo purchases and firearm order requests remain in their own sections.</p></div><button id="storeOrdersRefresh" type="button" class="secondary">Refresh orders</button></div><div id="storeOrdersStatus" role="status" aria-live="polite"></div><div id="storeOrdersList"></div></div>');
 const $=id=>panel.querySelector("#"+id);
 let owner=false,orders=[];
 async function load(){
  if(!owner)return;
  $("storeOrdersStatus").textContent="Loading orders…";
  const {data,error}=await client.from("gac_store_orders").select("*").order("created_at",{ascending:false});
  if(error)throw error;
  orders=data||[];onNewOrders(orders.filter(order=>order.fulfillment_status==="pending_fulfillment").length);render();$("storeOrdersStatus").textContent="";
 }
 function render(){
  const host=$("storeOrdersList");host.replaceChildren();
  if(!orders.length){host.append(text("p","No merchandise checkout orders yet. This list will fill after main-site checkout is connected."));return;}
  for(const order of orders){
   const details=document.createElement("details");details.className="editable-member";
   const summary=text("summary","Order "+order.order_number+" · "+order.customer_email+" · "+(STATUS_LABELS[order.fulfillment_status]||order.fulfillment_status)+" · "+money(order.total_cents));
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
    await load();status("Order "+order.order_number+" updated.");
   });
   body.append(fields,save);details.append(summary,body);host.append(details);
  }
 }
 $("storeOrdersRefresh").onclick=()=>action(load);
 return {sync(isOwner){owner=!!isOwner;return owner?load():Promise.resolve();},refreshOrders:load,clear(){owner=false;onNewOrders(0);orders=[];$("storeOrdersList").replaceChildren();$("storeOrdersStatus").textContent="";}};
}
