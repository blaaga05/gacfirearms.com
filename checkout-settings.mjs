export function mountCheckoutSettings({client,mount,action,status,onChanged=()=>{}}){
 let member=null,owner=false,enabled=false,epoch=0,loading=false;
 const root=document.createElement('section');root.hidden=true;root.className='payment-controls';
 const title=document.createElement('h3');title.textContent='Checkout controls';
 const state=document.createElement('p');state.setAttribute('role','status');
 const help=document.createElement('p');help.textContent='OFF stops new checkouts. Already opened payments can still finish. Final launch protections remain in place.';
 const toggle=document.createElement('button');toggle.type='button';toggle.setAttribute('role','switch');toggle.disabled=true;
 root.append(title,state,toggle,help);mount.prepend(root);
 function render(){root.hidden=!owner;state.textContent=enabled?'ON · Checkout switch enabled':'OFF · New checkout requests stopped';toggle.textContent=enabled?'Disable checkout':'Enable checkout';toggle.setAttribute('aria-checked',String(enabled));toggle.disabled=!owner||loading;onChanged(enabled);}
 async function reload(){if(!member||loading)return;loading=true;const v=epoch;try{const {data,error}=await client.rpc('gac_checkout_enabled');if(v!==epoch)return;if(error)throw error;enabled=data===true;}catch{if(v===epoch)enabled=false;}finally{if(v===epoch){loading=false;render();}}}
 toggle.onclick=()=>action(async()=>{if(!owner)throw Error('Owner access required');const v=epoch;loading=true;render();try{const {data,error}=await client.rpc('gac_owner_set_checkout_enabled',{p_enabled:!enabled});if(error)throw error;if(v!==epoch||!owner)return;enabled=data===true;status(enabled?'Checkout switch enabled. Launch/testing protections still apply.':'Checkout disabled. Already submitted payments will still be verified.');}finally{if(v===epoch){loading=false;render();}}});
 return{enabled:()=>enabled,async sync(profile,isOwner){if(member!==profile.user_id){epoch++;loading=false;enabled=false;}member=profile.user_id;owner=isOwner;render();await reload();},reload,clear(){epoch++;member=null;owner=false;enabled=false;loading=false;render();}};
}
