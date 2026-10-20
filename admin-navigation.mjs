export const ADMIN_SECTIONS=[
 {id:'collections',label:'Collections & Recognition',panels:[['collections','Groups & wheel'],['numberHolds','Numbers, holds & assignments'],['purchaseLogo','Purchase logos'],['wallpaper','Recognition wallpaper'],['recognitions','Recognition history']]},
 {id:'members',label:'Members & Messages',panels:[['members','Manage members'],['messages','Messages, announcements & welcome']]},
 {id:'inventory',label:'Inventory & Integrations',panels:[['firearms','Firearm inventory'],['merch','Merchandise & accessories'],['fastbound','FastBound connection']]},
 {id:'orders',label:'Orders & Shipping',panels:[['storeOrders','Order oversight & shipping']]},
 {id:'payments',label:'Payments',panels:[['payments','Checkout controls, transactions & refunds']]},
 {id:'settings',label:'Settings',panels:[['rules','Enrollment requirements']]}
];
export function mountAdminNavigation({admin,nav,panels,onSelect=()=>{}}){
 const groups=new Map(),aliases=new Map(),buttons=new Map(),details=new Map();
 nav.replaceChildren();
 for(const section of ADMIN_SECTIONS){
  const group=document.createElement('section');group.id='admin-section-'+section.id;group.hidden=true;group.setAttribute('aria-label',section.label);
  const heading=document.createElement('h2');heading.textContent=section.label;group.append(heading);
  for(const [key,label]of section.panels){const panel=panels[key];if(!panel)continue;
   const fold=document.createElement('details'),summary=document.createElement('summary');summary.textContent=label;summary.id='admin-heading-'+key;fold.className='admin-tool-section';fold.open=section.panels.length===1||key===section.panels[0][0];panel.hidden=false;panel.setAttribute('aria-labelledby',summary.id);fold.append(summary,panel);group.append(fold);details.set(key,fold);aliases.set(key,section.id);
  }
  groups.set(section.id,group);admin.append(group);
  const button=document.createElement('button');button.type='button';button.textContent=section.label;button.dataset.ownerPanel=section.id;button.id='admin-tab-'+section.id;button.setAttribute('aria-controls',group.id);button.onclick=()=>onSelect(section.id);buttons.set(section.id,button);nav.append(button);
 }
 if(panels.copy){panels.copy.hidden=true;panels.copy.setAttribute('aria-hidden','true');}
 const style=document.createElement('style');style.textContent='.admin-tool-section{border:1px solid #405140;border-radius:10px;margin:14px 0;overflow:hidden}.admin-tool-section>summary{padding:16px 18px;cursor:pointer;font-weight:700;color:#d4e4c9;background:#142019}.admin-tool-section>div{padding:12px}.admin-tool-section .card{margin-top:0}.owner-nav button{white-space:normal}';admin.append(style);
 function show(key){const id=groups.has(key)?key:aliases.get(key)||'collections';for(const [name,group]of groups)group.hidden=name!==id;for(const [name,button]of buttons){button.classList.toggle('active',name===id);button.setAttribute('aria-pressed',String(name===id));}if(key!==id&&details.has(key))details.get(key).open=true;if(panels.copy)panels.copy.hidden=true;return id;}
 return{show};
}
