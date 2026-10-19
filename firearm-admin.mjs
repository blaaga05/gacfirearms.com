const $=(root,id)=>root.querySelector("#"+id);
const money=cents=>new Intl.NumberFormat("en-US",{style:"currency",currency:"USD"}).format(cents/100);
const text=(tag,value)=>{const node=document.createElement(tag);node.textContent=value;return node};

export function mountFirearmAdmin({client,addAdmin,action,status}){
  const panel=addAdmin("firearms","Firearm inventory",'<div class="card"><h2>Serialized firearms</h2><p>Sync items from FastBound, set a public price and description, and choose which available items appear in the separate Firearms store. Serial numbers stay in this owner panel.</p><button id="firearmSync" type="button">Sync FastBound inventory</button><p id="firearmSyncStatus" role="status"></p><label for="firearmPick">Inventory item</label><select id="firearmPick"></select><form id="firearmEdit"><label for="firearmPrice">Website price ($)</label><input id="firearmPrice" type="number" min="0.01" max="1000000" step="0.01" required><label for="firearmDescription">Public description</label><textarea id="firearmDescription" maxlength="3000"></textarea><label for="firearmPhoto">Listing photo (JPG, PNG, or WebP · larger photos are compressed)</label><input id="firearmPhoto" type="file" accept="image/jpeg,image/png,image/webp"><p id="firearmPhotoStatus" role="status"></p><img id="firearmPhotoPreview" alt="Firearm listing photo preview" hidden style="display:none;max-width:100%;max-height:260px;object-fit:contain;margin:12px 0;border:1px solid #303a33"><button id="firearmPhotoRemove" type="button" class="secondary" hidden>Remove photo from listing</button><label class="check"><input id="firearmPublished" type="checkbox"><span>Publish on the Firearms page</span></label><button id="firearmSave">Save listing</button><p id="firearmEditStatus" role="status"></p></form></div><div class="card"><h2>Firearm order requests</h2><p>Requests are not paid orders or inventory reservations. Review the transfer details and contact the customer directly.</p><button id="firearmOrdersRefresh" type="button" class="secondary">Refresh requests</button><div id="firearmOrders"></div></div>');
  let owner=false,epoch=0,items=[],orders=[],pendingPhoto=null,removePhoto=false,previewUrl="";
  const read=async actionName=>{const {data,error}=await client.functions.invoke("gac-firearms-admin",{body:{action:actionName}});if(error)throw error;if(data?.error)throw Error(data.error);return data;};
  function selected(){return items.find(x=>x.fastbound_item_id===$(panel,"firearmPick").value);}
  async function preparePhoto(file){
    if(!["image/jpeg","image/png","image/webp"].includes(file.type))throw Error("Choose a JPG, PNG, or WebP photo.");
    if(file.size>30*1024*1024)throw Error("Choose a photo smaller than 30 MB.");
    if(file.size<=5*1024*1024)return {blob:file,type:file.type};
    if(typeof createImageBitmap!=="function")throw Error("This browser cannot resize the photo. Choose a JPG, PNG, or WebP under 5 MB.");
    let bitmap;
    try{bitmap=await createImageBitmap(file)}catch{throw Error("This photo could not be opened. Save it as JPG, PNG, or WebP and try again.");}
    try{
      const scale=Math.min(1,1800/Math.max(bitmap.width,bitmap.height));
      const canvas=document.createElement("canvas");canvas.width=Math.max(1,Math.round(bitmap.width*scale));canvas.height=Math.max(1,Math.round(bitmap.height*scale));
      const context=canvas.getContext("2d");if(!context)throw Error("The photo could not be prepared. Try a smaller image.");
      context.drawImage(bitmap,0,0,canvas.width,canvas.height);
      const blob=await new Promise(resolve=>canvas.toBlob(resolve,"image/webp",0.82));
      if(!blob)throw Error("The photo could not be compressed. Try a JPG under 5 MB.");
      if(blob.size>5*1024*1024)throw Error("This photo is still over 5 MB after resizing. Try a smaller image.");
      return {blob,type:blob.type};
    }finally{bitmap.close?.();}
  }
  function photoPreview(url){
    const image=$(panel,"firearmPhotoPreview");
    if(previewUrl.startsWith("blob:"))URL.revokeObjectURL(previewUrl);
    previewUrl=url||"";image.src=url||"";image.hidden=!url;image.style.display=url?"block":"none";$(panel,"firearmPhotoRemove").hidden=!url;
  }
  function edit(item){
    pendingPhoto=null;removePhoto=false;$(panel,"firearmPhoto").value="";
    if(!item){$(panel,"firearmPrice").value="";$(panel,"firearmDescription").value="";$(panel,"firearmPublished").checked=false;$(panel,"firearmPublished").disabled=true;photoPreview("");$(panel,"firearmEditStatus").textContent="No synced item selected.";return;}
    $(panel,"firearmPrice").value=item.price_cents?(item.price_cents/100).toFixed(2):"";
    $(panel,"firearmDescription").value=item.public_description||"";
    $(panel,"firearmPublished").checked=!!item.published;$(panel,"firearmPublished").disabled=!item.is_available;
    photoPreview(item.photo_path?client.storage.from("gac-product-images").getPublicUrl(item.photo_path).data.publicUrl:"");
    $(panel,"firearmEditStatus").textContent=item.manufacturer+" "+item.model+" · Serial "+item.serial_number+" · "+(item.is_available?"Available in FastBound":"Not currently available");
  }
  async function loadItems(){
    const version=epoch,data=await read("list");if(!owner||version!==epoch)return;
    items=data.items||[];const pick=$(panel,"firearmPick");const old=pick.value;pick.replaceChildren();
    for(const item of items){const option=document.createElement("option");option.value=item.fastbound_item_id;option.textContent=[item.manufacturer,item.model,item.serial_number,item.is_available?"Available":"Unavailable"].filter(Boolean).join(" · ");pick.append(option);}
    pick.value=items.some(x=>x.fastbound_item_id===old)?old:(items[0]?.fastbound_item_id||"");edit(selected());
  }
  async function loadOrders(){
    const version=epoch,data=await read("orders");if(!owner||version!==epoch)return;
    orders=data.orders||[];const host=$(panel,"firearmOrders");host.replaceChildren();
    if(!orders.length){host.append(text("p","No firearm requests yet."));return;}
    for(const order of orders){
      const row=document.createElement("details");row.className="firearm-request";
      const summary=text("summary",order.firearm_name+" · "+order.buyer_name+" · "+order.review_status.replaceAll("_"," "));
      const details=document.createElement("div");
      const ffl=order.transfer_method==="destination_ffl"?order.destination_ffl_name+" · "+order.destination_ffl_city+", "+order.destination_ffl_state+" · "+(order.destination_ffl_phone||order.destination_ffl_email):"Pickup request at GAC";
      details.append(text("p","Price shown: "+money(order.price_cents)+" · Residence: "+order.residence_state),text("p","Buyer: "+order.buyer_name+" · "+order.buyer_email+" · "+(order.buyer_phone||"No phone provided")),text("p","Transfer request: "+ffl),text("p",new Date(order.created_at).toLocaleString()));
      const select=document.createElement("select");for(const [value,label] of [["pending_review","Pending review"],["contacted","Contacted"],["declined","Declined"]]){const option=text("option",label);option.value=value;select.append(option);}select.value=order.review_status;
      const save=document.createElement("button");save.type="button";save.className="secondary";save.textContent="Update review status";
      save.onclick=()=>action(async()=>{const {data,error}=await client.functions.invoke("gac-firearms-admin",{body:{action:"review-request",requestId:order.id,status:select.value}});if(error)throw error;if(data?.error)throw Error(data.error);await loadOrders();status("Request status updated.");});
      details.append(select,save);row.append(summary,details);host.append(row);
    }
  }
  $(panel,"firearmEdit").addEventListener("invalid",event=>{if(event.target.id==="firearmPrice")$(panel,"firearmEditStatus").textContent="Enter the website price before saving the listing.";},true);
  $(panel,"firearmPick").onchange=()=>edit(selected());
  $(panel,"firearmPhoto").onchange=()=>{const file=$(panel,"firearmPhoto").files?.[0]||null;pendingPhoto=file;removePhoto=false;$(panel,"firearmPhotoStatus").textContent=file?(file.size>5*1024*1024?"Photo selected · it will be resized during save.":"Photo selected · save the listing to upload it."):"";if(file)photoPreview(URL.createObjectURL(file));else photoPreview(selected()?.photo_path?client.storage.from("gac-product-images").getPublicUrl(selected().photo_path).data.publicUrl:"");};
  $(panel,"firearmPhotoRemove").onclick=()=>{pendingPhoto=null;removePhoto=true;$(panel,"firearmPhoto").value="";photoPreview("");};
  $(panel,"firearmSync").onclick=()=>action(async()=>{if(!owner)throw Error("Owner access required.");$(panel,"firearmSyncStatus").textContent="Syncing FastBound inventory…";const result=await client.functions.invoke("gac-firearms-admin",{body:{action:"sync"}});if(result.error)throw result.error;if(result.data?.error)throw Error(result.data.error);await loadItems();$(panel,"firearmSyncStatus").textContent="Sync complete · "+result.data.imported+" serialized items checked at "+new Date(result.data.syncedAt).toLocaleString()+". Review each item before publishing.";status("FastBound inventory synced.");});
  $(panel,"firearmEdit").onsubmit=e=>{e.preventDefault();action(async()=>{if(!owner)throw Error("Owner access required.");const item=selected();if(!item)throw Error("Sync inventory and select an item first.");const raw=$(panel,"firearmPrice").value;const priceCents=Math.round(Number(raw)*100);if(!Number.isSafeInteger(priceCents)||priceCents<1)throw Error("Enter a valid website price.");let photoPath=item.photo_path||null;if(pendingPhoto){$(panel,"firearmPhotoStatus").textContent="Preparing photo…";try{const prepared=await preparePhoto(pendingPhoto);const ext={"image/jpeg":"jpg","image/png":"png","image/webp":"webp"}[prepared.type];if(!ext)throw Error("The browser returned an unsupported photo format.");photoPath="firearms/"+item.fastbound_item_id+"/"+crypto.randomUUID()+"."+ext;$(panel,"firearmPhotoStatus").textContent="Uploading photo…";const {error:uploadError}=await client.storage.from("gac-product-images").upload(photoPath,prepared.blob,{contentType:prepared.type,upsert:false});if(uploadError)throw uploadError;}catch(error){$(panel,"firearmPhotoStatus").textContent=error.message||"Photo upload failed. Try a smaller JPG, PNG, or WebP.";throw error;}}else if(removePhoto)photoPath=null;const {data,error}=await client.functions.invoke("gac-firearms-admin",{body:{action:"update",itemId:item.fastbound_item_id,priceCents,description:$(panel,"firearmDescription").value,published:$(panel,"firearmPublished").checked,photoPath}});if(error)throw error;if(data?.error)throw Error(data.error);pendingPhoto=null;removePhoto=false;$(panel,"firearmPhotoStatus").textContent=photoPath?"Photo saved with listing.":"";await loadItems();$(panel,"firearmEditStatus").textContent="Listing saved. Public details do not include the serial number.";status("Firearm listing saved.");});};
  $(panel,"firearmOrdersRefresh").onclick=()=>action(loadOrders);
  return {async sync(isOwner){if(owner!==isOwner){epoch++;owner=isOwner;}if(!owner)return;await loadItems();await loadOrders();},clear(){epoch++;owner=false;items=[];orders=[];pendingPhoto=null;removePhoto=false;$(panel,"firearmPick").replaceChildren();$(panel,"firearmOrders").replaceChildren();$(panel,"firearmSyncStatus").textContent="";photoPreview("");edit(null);}};
}
