export function personalRecognitionReady(collection,entries,rounds,now){
 const expected=Math.min(Number(collection?.spin_count||1),entries.length),latest=rounds.at(-1);
 return collection?.state==='recognized'&&expected>0&&rounds.length>=expected&&!!latest&&now>=Date.parse(latest.selected_at)+Number(collection.wheel_settings?.duration||14)*1000+10000;
}
/** Shared display only. Results and reveal times come from the server. */
export function sharedRecognition(collection,entries,rounds,now){
 if(!collection||!rounds.length)return null;
 const duration=Number(collection.wheel_settings?.duration||14)*1000;
 const latest=rounds.at(-1),reveal=Date.parse(latest.selected_at)+duration;
 const hasNext=rounds.length<Math.min(Number(collection.spin_count||1),entries.length);
 const closeAt=Math.min(reveal+10000,hasNext?reveal+Number(collection.spin_pause_seconds||15)*1000:Infinity);
 if(now<reveal||now>=closeAt)return null;
 return {key:collection.id+'|'+latest.spin_number+'|'+latest.selected_at+'|'+latest.edition_number,callsign:latest.callsign,group:collection.callsign,number:latest.edition_number,spin:latest.spin_number||1,total:Math.min(Number(collection.spin_count||1),entries.length),test:!!collection.is_test,seconds:Math.ceil((closeAt-now)/1000),fraction:(closeAt-now)/Math.min(10000,closeAt-reveal)};
}
export function mountSharedRecognition(){
 const el=(tag,text)=>{const e=document.createElement(tag);e.textContent=text;return e};
 const style=el('style','');style.textContent='.shared-recognition{position:fixed;left:50%;top:50%;transform:translate(-50%,-50%);z-index:50;width:min(380px,calc(100vw - 40px));padding:24px;box-sizing:border-box;border:1px solid #a9c498;border-radius:16px;background:#101b14;box-shadow:0 18px 80px #000c,0 0 36px #7fa76655;color:#edf3e9;text-align:center}.shared-recognition[hidden]{display:none}.shared-recognition.reveal{animation:gacRecognitionReveal .45s ease-out}.shared-recognition h2{font-size:18px;margin:10px 0;font-weight:500}.shared-recognition .recognition-winner{font-size:clamp(28px,7vw,40px);font-weight:800;line-height:1.15;color:#d7edcc;margin:14px 0 20px;overflow-wrap:anywhere}.shared-recognition p{margin:10px 0;line-height:1.5}.shared-recognition img{width:60px;height:60px;object-fit:contain;border-radius:50%;background:#080e09}.shared-recognition .recognition-mini-timer{font-size:13px;color:#bed2b6;font-variant-numeric:tabular-nums}.shared-recognition .recognition-progress{height:3px;background:#a9c498;transform-origin:left;border-radius:3px}.shared-recognition button{margin:12px 0 0;width:100%;padding:12px;background:#a9bc9b;color:#101711;border:1px solid #a9bc9b;border-radius:8px;font:inherit;cursor:pointer}@keyframes gacRecognitionReveal{from{opacity:0;transform:translate(-50%,-50%) scale(.94);box-shadow:0 0 70px #b7e1a7aa}to{opacity:1;transform:translate(-50%,-50%) scale(1)}}@media(prefers-reduced-motion:reduce){.shared-recognition.reveal{animation:none}}';document.head.append(style);
 const card=el('section','');card.className='shared-recognition';card.hidden=true;card.setAttribute('role','status');card.setAttribute('aria-live','polite');
 const logo=el('img','');logo.src='/assets/gac-logo-v3.png';logo.alt='GAC';const heading=el('h2','Congrats'),body=el('p',''),details=el('p',''),timer=el('div',''),progress=el('div',''),ack=el('button','Acknowledged');
 body.className='recognition-winner';timer.className='recognition-mini-timer';timer.setAttribute('aria-live','off');progress.className='recognition-progress';progress.setAttribute('aria-hidden','true');ack.type='button';card.append(logo,heading,body,details,timer,progress,ack);document.body.append(card);
 let active=null;const acknowledged=new Set();ack.onclick=()=>{if(active)acknowledged.add(active);card.hidden=true;};
 function update(collection,entries,rounds,now,visible){const result=visible?sharedRecognition(collection,entries,rounds,now):null;if(!result||acknowledged.has(result.key)){card.hidden=true;return}if(active!==result.key){active=result.key;card.classList.remove('reveal');heading.textContent=(result.test?'TEST · ':'')+'Congrats';body.textContent='#'+result.number+' · '+result.callsign+'!';details.textContent=result.group+' has been added to your collection.';card.hidden=false;void card.offsetWidth;card.classList.add('reveal');}else card.hidden=false;timer.textContent='Closing in '+result.seconds+' second'+(result.seconds===1?'':'s')+'…';progress.style.transform='scaleX('+Math.max(0,result.fraction)+')';}
 return {update,get visible(){return !card.hidden},clear(){acknowledged.clear();active=null;card.hidden=true;body.textContent='';details.textContent='';timer.textContent='';}};
}
