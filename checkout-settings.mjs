export function mountCheckoutSettings({client,mount,action,status,onChanged=()=>{}}){
 let member=null,owner=false,enabled=false,epoch=0,loading=false,merchEnabled=false,merchReady=false;
 const sandbox=location.hostname==='payment-sandbox.gacfirearms-com.pages.dev';
 const el=(tag,text)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;return e;};
 const root=el('section');root.hidden=true;root.className='payment-controls';
 root.append(el('h3','Checkout controls'));
 const grid=el('div');grid.style.cssText='display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,240px),1fr));gap:16px';
 function control(title){const box=el('section'),state=el('p'),toggle=el('button');box.style.cssText='padding:16px;border:1px solid #405140;border-radius:10px';state.setAttribute('role','status');toggle.type='button';toggle.setAttribute('role','switch');toggle.disabled=true;box.append(el('h4',title),state,toggle);grid.append(box);return{state,toggle};}
 const memberControl=control('Member checkout'),merchControl=control('Public merchandise checkout');
 root.append(grid);mount.prepend(root);
 function paint(control,on,ready=true){control.state.textContent=ready?(on?'ENABLED':'DISABLED'):'DISABLED · Live merchandise checkout is not ready';
 control.toggle.textContent=ready?(on?'Enabled · Click to disable':'Disabled · Click to enable'):'Unavailable until merchandise testing is complete';
 control.toggle.setAttribute('aria-checked',String(on&&ready));control.toggle.disabled=!owner||loading||!ready;
 control.toggle.style.cssText='background:'+(on&&ready?'#245c3b':'#732e32')+';color:#fff;border:1px solid '+(on&&ready?'#65b582':'#d28b8e')+';border-radius:6px;padding:6px 9px;min-height:34px;max-width:100%;white-space:normal;opacity:'+(ready?'1':'.7');
 }
 function render(){root.hidden=!owner;paint(memberControl,enabled);paint(merchControl,merchEnabled,merchReady);onChanged(enabled);}
 async function reload(){if(!member||loading)return;loading=true;const v=epoch;try{
 const results=await Promise.allSettled([client.rpc('gac_checkout_enabled'),owner&&sandbox?client.rpc('gac_owner_merch_checkout',{}):Promise.resolve({data:false,error:null})]);
 if(v!==epoch)return;const m=results[0],p=results[1];enabled=m.status==='fulfilled'&&!m.value.error&&m.value.data===true;merchReady=owner&&sandbox&&p.status==='fulfilled'&&!p.value.error;merchEnabled=merchReady&&p.value.data===true;
 }finally{if(v===epoch){loading=false;render();}}}
 async function change(kind){if(!owner)throw Error('Owner access required');if(kind==='merch'&&!merchReady)throw Error('Public merchandise checkout is not ready');
 const v=epoch;loading=true;render();try{const isMerch=kind==='merch';const{data,error}=await client.rpc(isMerch?'gac_owner_merch_checkout':'gac_owner_set_checkout_enabled',{p_enabled:!(isMerch?merchEnabled:enabled)});if(error)throw error;if(v!==epoch||!owner)return;if(isMerch)merchEnabled=data===true;else enabled=data===true;
 status((isMerch?'Public merchandise':'Member')+' checkout '+(data===true?'enabled. Launch/testing protections still apply.':'disabled. Already submitted payments will still be verified.'));
 }finally{if(v===epoch){loading=false;render();}}}
 memberControl.toggle.onclick=()=>action(()=>change('member'));merchControl.toggle.onclick=()=>action(()=>change('merch'));
 return{enabled:()=>enabled,async sync(profile,isOwner){if(member!==profile.user_id){epoch++;loading=false;enabled=false;merchEnabled=false;merchReady=false;}member=profile.user_id;owner=isOwner;render();await reload();},reload,clear(){epoch++;member=null;owner=false;enabled=false;merchEnabled=false;merchReady=false;loading=false;render();}};
}
