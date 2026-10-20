const SUPABASE_URL="https://yuuagwxqhxiiybwjhome.supabase.co";
const KEY="sb_publishable_iYZBPKMeGQlAnst_uXBsRA_V0UL4z8L";
const products=document.getElementById("firearmProducts"),dialog=document.getElementById("firearmOrderDialog"),form=document.getElementById("firearmOrderForm");
let selected=null;
const make=(tag,content)=>{const e=document.createElement(tag);if(content!==undefined)e.textContent=content;return e};
const money=value=>new Intl.NumberFormat("en-US",{style:"currency",currency:"USD"}).format(value/100);
function showError(message){products.replaceChildren(make("p",message));products.firstChild.className="empty"}
function render(items){
  products.replaceChildren();
  if(!items.length){const empty=make("p","No firearms are listed at this time. Check back later or contact GAC.");empty.className="empty";products.append(empty);return}
  for(const item of items){
    const card=make("article");card.className="card";
    const maker=make("div","GASSETT ARMS COMPANY");maker.className="eyebrow";
    const name=make("h2",[item.manufacturer,item.model].filter(Boolean).join(" "));
    if(item.photo_path){const photoButton=make("button");photoButton.type="button";photoButton.className="photo-preview";photoButton.setAttribute("aria-haspopup","dialog");photoButton.setAttribute("aria-label","View larger photo of "+[item.manufacturer,item.model].filter(Boolean).join(" ")+" firearm");const image=make("img");image.src=SUPABASE_URL+"/storage/v1/object/public/gac-product-images/"+item.photo_path.split("/").map(encodeURIComponent).join("/");image.alt=[item.manufacturer,item.model].filter(Boolean).join(" ")+" firearm";image.loading="lazy";image.decoding="async";photoButton.append(image);photoButton.onclick=()=>{const viewer=document.getElementById("firearmPhotoViewer"),large=document.getElementById("firearmPhotoLarge");large.src=image.src;large.alt=image.alt;viewer.showModal();};card.append(photoButton);}
    const meta=make("p",[item.firearm_type,item.caliber,item.condition].filter(Boolean).join(" · "));meta.className="meta";
    const price=make("div",money(item.price_cents));price.className="price";
    const description=make("p",item.public_description||"Contact GAC with questions about this firearm.");
    const button=make("button","Request order review");button.type="button";button.onclick=()=>openRequest(item);
    const checkout=make("button","Firearm checkout coming soon");checkout.type="button";checkout.className="secondary";checkout.disabled=true;checkout.setAttribute("aria-label","Firearm checkout coming soon for "+[item.manufacturer,item.model].filter(Boolean).join(" "));
    card.append(maker,name,meta,price,description,button,checkout);products.append(card);
  }
}
async function load(){
  try{
    const response=await fetch(SUPABASE_URL+"/rest/v1/gac_firearm_catalog?select=id,manufacturer,model,caliber,firearm_type,condition,price_cents,public_description,photo_path&order=manufacturer.asc,model.asc",{
      headers:{apikey:KEY,Accept:"application/json"},cache:"no-store",signal:AbortSignal.timeout(12000)
    });
    if(!response.ok)throw new Error("Catalog is temporarily unavailable.");
    render(await response.json());
  }catch{showError("Firearms could not load. Please refresh or contact GAC.")}
}
function openRequest(item){
  selected=item;document.getElementById("selectedFirearm").textContent=[item.manufacturer,item.model,item.caliber,money(item.price_cents)].filter(Boolean).join(" · ");
  document.getElementById("orderStatus").textContent="";
  form.reset();document.getElementById("destinationFflFields").hidden=true;
  for(const id of ["fflName","fflCity","fflState","fflPhone","fflEmail"]){document.getElementById(id).required=false}
  dialog.showModal();
}
document.getElementById("closeOrder").onclick=()=>dialog.close();
const photoViewer=document.getElementById("firearmPhotoViewer");
document.getElementById("closePhotoViewer").onclick=()=>photoViewer.close();
photoViewer.addEventListener("click",event=>{if(event.target===photoViewer)photoViewer.close()});
form.querySelectorAll('input[name="transferMethod"]').forEach(input=>input.addEventListener("change",()=>{
  const ffl=form.querySelector('input[name="transferMethod"]:checked')?.value==="destination_ffl";
  const fields=document.getElementById("destinationFflFields");fields.hidden=!ffl;
  for(const id of ["fflName","fflCity","fflState"]){document.getElementById(id).required=ffl}
  document.getElementById("fflPhone").required=ffl;
  document.getElementById("fflEmail").required=false;
}));
form.onsubmit=async event=>{
  event.preventDefault();if(!selected)return;
  const button=form.querySelector('button[type="submit"]'),status=document.getElementById("orderStatus");
  button.disabled=true;status.textContent="Sending request…";
  const body={
    firearmId:selected.id,name:form.elements.name.value,email:form.elements.email.value,phone:form.elements.phone.value,
    state:form.elements.state.value,transferMethod:form.elements.transferMethod.value,
    fflName:document.getElementById("fflName").value,fflCity:document.getElementById("fflCity").value,
    fflState:document.getElementById("fflState").value,fflPhone:document.getElementById("fflPhone").value,
    fflEmail:document.getElementById("fflEmail").value,
    eligible:document.getElementById("buyerEligible").checked,understandsReview:document.getElementById("buyerUnderstands").checked
  };
  try{
    const response=await fetch(SUPABASE_URL+"/functions/v1/gac-firearm-order-request",{method:"POST",headers:{apikey:KEY,"Content-Type":"application/json"},body:JSON.stringify(body),signal:AbortSignal.timeout(15000)});
    const result=await response.json().catch(()=>({}));
    if(!response.ok)throw new Error(result.error||"The request could not be sent. Please contact GAC.");
    form.reset();document.getElementById("destinationFflFields").hidden=true;
    for(const id of ["fflName","fflCity","fflState","fflPhone","fflEmail"]){document.getElementById(id).required=false}
    status.textContent="Request received. This is not a reservation or charge. GAC will contact you to review availability and transfer details.";
  }catch(error){status.textContent=error.message||"Request could not be sent."}
  finally{button.disabled=false}
};
load();
