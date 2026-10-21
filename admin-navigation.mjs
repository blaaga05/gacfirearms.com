export const ADMIN_SECTIONS=[
 {id:'collections',label:'Collections & Recognition',panels:[['collections','Groups & wheel'],['numberHolds','Numbers, holds & assignments'],['purchaseLogo','Purchase logos'],['wallpaper','Recognition wallpaper'],['recognitions','Recognition history']]},
 {id:'members',label:'Members & Messages',panels:[['messages','Messages, announcements & welcome'],['members','Manage members']]},
 {id:'inventory',label:'Inventory & Integrations',panels:[['firearms','Firearm inventory'],['merch','Merchandise & accessories'],['fastbound','FastBound connection']]},
 {id:'orders',label:'Orders & Shipping',panels:[['storeOrders','Order oversight & shipping']]},
 {id:'payments',label:'Payments',panels:[['payments','Checkout controls, transactions & refunds']]},
 {id:'settings',label:'Settings',panels:[['rules','Enrollment requirements']]}
];
export function mountAdminNavigation({admin,nav,panels,onSelect=()=>{}}){
 const groups=new Map(),aliases=new Map(),buttons=new Map(),details=new Map(),indicators=new Map();
 nav.replaceChildren();
 for(const section of ADMIN_SECTIONS){
  const group=document.createElement('section');group.id='admin-section-'+section.id;group.hidden=true;group.setAttribute('aria-label',section.label);
  const heading=document.createElement('h2');heading.textContent=section.label;group.append(heading);
  for(const [key,label]of section.panels){const panel=panels[key];if(!panel)continue;
   const fold=document.createElement('details'),summary=document.createElement('summary');summary.textContent=label;summary.id='admin-heading-'+key;fold.className='admin-tool-section';fold.open=section.panels.length===1||key===section.panels[0][0];panel.hidden=false;panel.setAttribute('aria-labelledby',summary.id);const collapse=document.createElement('button');collapse.type='button';collapse.className='secondary admin-collapse-button';collapse.textContent='Collapse section';collapse.setAttribute('aria-label','Collapse '+label);collapse.onclick=()=>{fold.open=false;summary.focus();};fold.append(summary,panel,collapse);group.append(fold);details.set(key,fold);aliases.set(key,section.id);
  }
  groups.set(section.id,group);admin.append(group);
  const button=document.createElement('button');button.type='button';button.textContent=section.label;button.dataset.ownerPanel=section.id;button.dataset.sectionLabel=section.label;const indicator=document.createElement('span');indicator.className='admin-new-indicator';indicator.hidden=true;indicator.setAttribute('aria-hidden','true');button.append(indicator);indicators.set(section.id,indicator);button.id='admin-tab-'+section.id;button.setAttribute('aria-controls',group.id);button.onclick=()=>onSelect(section.id);buttons.set(section.id,button);nav.append(button);
 }
 if(panels.copy){panels.copy.hidden=true;panels.copy.setAttribute('aria-hidden','true');}
 const style=document.createElement('style');style.textContent='.admin-new-indicator{display:inline-flex;align-items:center;justify-content:center;margin-left:8px;padding:3px 7px;border-radius:999px;background:#b53e3e;color:#fff;font-size:10px;font-weight:800;line-height:1;white-space:nowrap}.admin-new-indicator[hidden]{display:none}.admin-tool-section{border:1px solid #405140;border-radius:10px;margin:14px 0;overflow:hidden}.admin-tool-section>summary{padding:16px 18px;cursor:pointer;font-weight:700;color:#d4e4c9;background:#142019}.admin-tool-section>div{padding:12px}.admin-tool-section .card{margin-top:0}.admin-collapse-button{display:block;margin:10px 12px 12px auto;padding:8px 12px;font-size:13px}.owner-nav button{white-space:normal}';admin.append(style);
 function show(key){const id=groups.has(key)?key:aliases.get(key)||'collections';for(const [name,group]of groups)group.hidden=name!==id;for(const [name,button]of buttons){button.classList.toggle('active',name===id);button.setAttribute('aria-pressed',String(name===id));}if(key!==id&&details.has(key))details.get(key).open=true;if(panels.copy)panels.copy.hidden=true;return id;}
 return{show,setIndicator(id,count,kind='orders'){const button=buttons.get(id),indicator=indicators.get(id),total=Math.max(0,Number(count)||0);if(!button||!indicator)return;indicator.hidden=total===0;indicator.textContent=total?(total===1?'NEW':'NEW '+total):'';button.setAttribute('aria-label',total?button.dataset.sectionLabel+', '+total+' new '+kind:button.dataset.sectionLabel);button.title=total?total+' new '+kind:'';}};
}
