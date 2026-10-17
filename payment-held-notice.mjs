export function mountHeldPaymentNotice({client,openMessages=()=>{},clock=()=>Date.now()}){
 const el=(tag,text)=>{const e=document.createElement(tag);e.textContent=text;return e;};
 const dialog=el('dialog','');dialog.className='payment-review-popup';dialog.setAttribute('aria-labelledby','heldPaymentTitle');dialog.setAttribute('aria-describedby','heldPaymentWarning');
 const title=el('h2','Your payment is pending review');title.id='heldPaymentTitle';
 const warning=el('p','Do not pay again or buy another number for this purchase.');warning.id='heldPaymentWarning';warning.style.cssText='font-size:22px;font-weight:bold;color:#ffe1a6';
 const details=el('p',''),hold=el('p',''),explanation=el('p','Authorize.net is reviewing this payment. It has not been credited to your account or added to the wheel. The review does not extend your number hold. Message GAC if you need help.'),message=el('button','Message GAC'),ack=el('button','I understand');
 message.type=ack.type='button';ack.className='secondary';dialog.append(title,warning,details,hold,explanation,message,ack);document.body.append(dialog);dialog.addEventListener('cancel',e=>e.preventDefault());
 let offset=0;let member=null,epoch=0,busy=false,current=null,rows=[];const seen=new Set();
 const key=r=>r.transaction_id+':'+(r.hold_expires_at&&Date.parse(r.hold_expires_at)>clock()+offset?'held':'expired');
 function dismiss(){if(current)seen.add(key(current));current=null;dialog.close();}
 ack.onclick=dismiss;message.onclick=()=>{dismiss();openMessages();};
 function render(r){details.textContent=r.collection+' · Numbers '+r.numbers.join(', ')+' · Reference '+r.transaction_id;const valid=r.hold_expires_at&&Date.parse(r.hold_expires_at)>clock()+offset;hold.textContent=valid?'Your number is only temporarily held until '+new Date(r.hold_expires_at).toLocaleTimeString()+'. Approval is still pending.':'Your original hold has ended or changed. Your number is not secured. Contact GAC before making another purchase.';}
 function tick(){if(current)render(current);}
 async function poll(){if(!member||busy||document.hidden)return;busy=true;const version=epoch;try{const {data,error}=await client.rpc('gac_my_held_payments');if(error)throw error;if(version!==epoch||!member)return;rows=data||[];if(rows[0]?.server_time)offset=Date.parse(rows[0].server_time)-clock();if(current){const live=rows.find(r=>r.transaction_id===current.transaction_id);if(live){current=live;render(live);return;}current=null;dialog.close();}
 if(document.querySelector('dialog[open]'))return;
 const next=rows.find(r=>!seen.has(key(r)));if(!next)return;current=next;render(next);dialog.showModal();ack.focus();
 }finally{busy=false;}}
 return {async sync(profile){if(member!==profile.user_id){epoch++;seen.clear();current=null;rows=[];dialog.close();}member=profile.user_id;await poll();},poll,tick,clear(){epoch++;offset=0;member=null;current=null;rows=[];seen.clear();dialog.close();}};
}

