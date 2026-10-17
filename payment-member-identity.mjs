export function appendPaymentIdentity({row,record:r,openMember,messageMember}){
 const el=(tag,text)=>{const e=document.createElement(tag);e.textContent=text;return e;};
 const name=el('strong',[r.callsign,r.full_name].filter(Boolean).join(' · ')||'Member information unavailable');name.style.cssText='display:block;font-size:20px';
 const info=el('p',r.collection+' · Numbers '+(r.numbers||[]).join(', ')+' · '+new Intl.NumberFormat('en-US',{style:'currency',currency:r.currency||'USD'}).format(r.amount_cents/100)+' · '+String(r.status||'review').replaceAll('_',' '));
 row.append(name,info);
 if(r.contact_email){const email=el('a',r.contact_email);email.href='mailto:'+r.contact_email;email.style.display='block';row.append(email);}
 const details=el('button','Member details'),message=el('button','Message member');details.type=message.type='button';details.className=message.className='secondary';details.disabled=message.disabled=!r.member_id;details.onclick=()=>openMember(r.member_id);message.onclick=()=>messageMember(r.member_id);row.append(details,message);
 const reference=el('p','Transaction '+r.transaction_id+(r.observed_at?' · '+new Date(r.observed_at).toLocaleString():r.created_at?' · '+new Date(r.created_at).toLocaleString():''));reference.className='small';row.append(reference);
}

