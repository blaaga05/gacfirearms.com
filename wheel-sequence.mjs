/** Presentation only: eligible draws and timing are enforced by the server. */
export function wheelSequence(collection,entries,rounds,now){
 const duration=Number(collection?.wheel_settings?.duration||14)*1000;
 const completed=rounds.filter(r=>now>=Date.parse(r.selected_at)+duration);
 const latest=rounds.at(-1)||null;
 const single=Number(collection?.spin_count||1)===1;
 const removed=new Set(completed.map(r=>r.edition_number));
 if(single&&latest)removed.delete(latest.edition_number);
 const remaining=entries.filter(e=>!removed.has(e.edition_number));
 const animating=latest&&now<Date.parse(latest.selected_at)+duration;
 const nextAt=latest&&!single&&rounds.length<Number(collection.spin_count)&&entries.length>rounds.length?Date.parse(latest.selected_at)+duration+Number(collection.spin_pause_seconds||15)*1000:null;
 return {completed,remaining,result:animating||single?latest:null,nextAt,last:completed.at(-1)||null,animating:Boolean(animating)};
}
