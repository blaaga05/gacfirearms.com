const firearms=[
{id:'ar15',manufacturer:'GAC',model:'GA-15 Builder Platform',platform:'AR-15',caliber:'5.56 NATO',action:'Semi-auto',price:899,weight:6.4,icon:'—═╦═'},
{id:'glock19',manufacturer:'Glock',model:'19 Gen 5 MOS',platform:'Pistol',caliber:'9mm',action:'Semi-auto',price:620,weight:1.48,icon:'▰'},
{id:'sigp365',manufacturer:'SIG Sauer',model:'P365 X-Macro',platform:'Pistol',caliber:'9mm',action:'Semi-auto',price:819,weight:1.35,icon:'▰'},
{id:'mp15',manufacturer:'Smith & Wesson',model:'M&P15 Sport III',platform:'AR-15',caliber:'5.56 NATO',action:'Semi-auto',price:799,weight:6.8,icon:'—═╦═'},
{id:'rug556',manufacturer:'Ruger',model:'AR-556',platform:'AR-15',caliber:'5.56 NATO',action:'Semi-auto',price:829,weight:6.5,icon:'—═╦═'},
{id:'walterpdp',manufacturer:'Walther',model:'PDP Compact',platform:'Pistol',caliber:'9mm',action:'Semi-auto',price:649,weight:1.55,icon:'▰'}
];
const categories={
AR15:['Optic','Stock','Grip','Handguard','Light','Muzzle Device'],
Pistol:['Optic','Light','Magazine','Sights','Finish']
};
const parts=[
{id:'o1',category:'Optic',name:'Holosun HS510C',platforms:['AR-15'],price:309,weight:.31,fit:'Confirmed compatible'},
{id:'o2',category:'Optic',name:'Vortex Strike Eagle 1-6x',platforms:['AR-15'],price:399,weight:1.15,fit:'Requires compatible mount'},
{id:'o3',category:'Optic',name:'Trijicon RMR Type 2',platforms:['Pistol'],models:['glock19'],price:499,weight:.08,fit:'MOS plate required'},
{id:'o4',category:'Optic',name:'Holosun SCS MOS',platforms:['Pistol'],models:['glock19'],price:349,weight:.08,fit:'Direct MOS fit'},
{id:'s1',category:'Stock',name:'B5 Systems SOPMOD',platforms:['AR-15'],price:95,weight:.72,fit:'Mil-spec buffer tube'},
{id:'s2',category:'Stock',name:'Magpul CTR',platforms:['AR-15'],price:65,weight:.55,fit:'Mil-spec buffer tube'},
{id:'g1',category:'Grip',name:'Magpul MOE-K2',platforms:['AR-15'],price:24,weight:.18,fit:'AR-pattern grip mount'},
{id:'h1',category:'Handguard',name:'Aero ATLAS R-ONE 15 inch',platforms:['AR-15'],price:229,weight:.85,fit:'AR-15 upper compatible'},
{id:'h2',category:'Handguard',name:'BCM MCMR 13 inch',platforms:['AR-15'],price:249,weight:.72,fit:'AR-15 upper compatible'},
{id:'l1',category:'Light',name:'Streamlight ProTac HL-X',platforms:['AR-15'],price:139,weight:.39,fit:'Picatinny/M-LOK mount'},
{id:'l2',category:'Light',name:'SureFire X300 Turbo',platforms:['Pistol'],models:['glock19'],price:369,weight:.28,fit:'Universal rail fit'},
{id:'m1',category:'Muzzle Device',name:'SureFire WarComp 1/2x28',platforms:['AR-15'],price:169,weight:.23,fit:'Verify barrel thread pattern'},
{id:'m2',category:'Magazine',name:'Glock OEM 15-round Magazine',platforms:['Pistol'],models:['glock19'],price:30,weight:.18,fit:'Glock 19 Gen 5'},
{id:'si1',category:'Sights',name:'AmeriGlo GL-429',platforms:['Pistol'],models:['glock19'],price:65,weight:.03,fit:'Glock-compatible dovetail'},
{id:'f1',category:'Finish',name:'GAC Graphite Cerakote Preview',platforms:['Pistol','AR-15'],price:225,weight:0,fit:'Service quote required'}
];
let state={base:null,category:null,selections:{}};
const $=s=>document.querySelector(s); const $$=s=>[...document.querySelectorAll(s)];
function showView(id){$$('.view').forEach(v=>v.classList.toggle('active',v.id===id));scrollTo({top:0,behavior:'smooth'});if(id==='saved')renderSaved();}
$$('[data-view]').forEach(b=>b.addEventListener('click',()=>showView(b.dataset.view)));
$$('[data-build-preset]').forEach(b=>b.addEventListener('click',()=>{showView('builder');$('#baseFirearmSelect').value=b.dataset.buildPreset;selectBase(b.dataset.buildPreset)}));
function populateFilters(){[...new Set(firearms.map(f=>f.manufacturer))].sort().forEach(m=>$('#manufacturerFilter').insertAdjacentHTML('beforeend',`<option>${m}</option>`));}
function renderCatalog(){const q=$('#searchInput').value.toLowerCase();const p=$('#platformFilter').value;const m=$('#manufacturerFilter').value;const list=firearms.filter(f=>(p==='all'||f.platform===p)&&(m==='all'||f.manufacturer===m)&&`${f.manufacturer} ${f.model} ${f.caliber}`.toLowerCase().includes(q));$('#catalogGrid').innerHTML=list.map(f=>`<article class="catalog-card"><div class="catalog-visual">${f.icon}</div><div class="catalog-body"><p class="eyebrow">${f.manufacturer}</p><h3>${f.model}</h3><p>${f.platform} · ${f.caliber}</p><div class="spec-row"><span>Starting price</span><strong>$${f.price.toLocaleString()}</strong></div><div class="spec-row"><span>Weight</span><strong>${f.weight} lb</strong></div><button class="primary-btn" onclick="openBuilder('${f.id}')">Customize</button></div></article>`).join('')||'<p>No firearms match those filters.</p>';}
window.openBuilder=id=>{showView('builder');$('#baseFirearmSelect').value=id;selectBase(id)};
function setupBuilder(){$('#baseFirearmSelect').innerHTML='<option value="">Choose a firearm...</option>'+firearms.filter(f=>['ar15','glock19'].includes(f.id)).map(f=>`<option value="${f.id}">${f.manufacturer} ${f.model}</option>`).join('');$('#baseFirearmSelect').addEventListener('change',e=>selectBase(e.target.value));}
function selectBase(id){state={base:firearms.find(f=>f.id===id)||null,category:null,selections:{}};renderBuilder();}
function platformKey(){return state.base?.platform==='AR-15'?'AR15':'Pistol'}
function renderBuilder(){if(!state.base){$('#builderTitle').textContent='Build your setup';$('#builderSubtitle').textContent='Choose a base firearm to begin.';$('#categoryButtons').innerHTML='';$('#visualStage').innerHTML='<p style="color:#98a1a9">Select a base firearm.</p>';return}$('#builderTitle').textContent=`Build: ${state.base.model}`;$('#builderSubtitle').textContent=`${state.base.manufacturer} · ${state.base.caliber}`;const cats=categories[platformKey()];state.category=state.category||cats[0];$('#categoryButtons').innerHTML=cats.map(c=>`<button class="${c===state.category?'active':''}" onclick="selectCategory('${c}')">${c}</button>`).join('');renderParts();renderVisual();}
window.selectCategory=c=>{state.category=c;renderBuilder()};
function compatibleParts(){return parts.filter(p=>p.category===state.category&&p.platforms.includes(state.base.platform)&&(!p.models||p.models.includes(state.base.id)))}
function renderParts(){const available=compatibleParts();$('#partsTitle').textContent=state.category;$('#partsList').innerHTML=available.map(p=>`<article class="part-card ${state.selections[p.category]?.id===p.id?'selected':''}"><h3>${p.name}</h3><p>${p.fit}</p><div class="part-row"><strong>$${p.price}</strong><button class="small-btn" onclick="togglePart('${p.id}')">${state.selections[p.category]?.id===p.id?'Remove':'Add'}</button></div></article>`).join('')||'<p style="color:#98a1a9">No verified parts in this prototype category.</p>';}
window.togglePart=id=>{const p=parts.find(x=>x.id===id);state.selections[p.category]=state.selections[p.category]?.id===id?null:p;renderBuilder()};
function totals(){const selected=Object.values(state.selections).filter(Boolean);return{price:(state.base?.price||0)+selected.reduce((s,p)=>s+p.price,0),weight:(state.base?.weight||0)+selected.reduce((s,p)=>s+p.weight,0),selected};}
function renderVisual(){const t=totals();$('#compatibilityBadge').textContent='Compatibility filtered';$('#buildWeight').textContent=`Estimated weight: ${t.weight.toFixed(2)} lb`;$('#buildTotal').textContent=`$${t.price.toLocaleString()}`;$('#visualStage').innerHTML=`<div class="platform-display"><div class="platform-icon">${state.base.icon}</div><h2>${state.base.manufacturer} ${state.base.model}</h2><div class="selected-chips">${t.selected.length?t.selected.map(p=>`<span class="chip">${p.category}: ${p.name}</span>`).join(''):'<span class="chip">Choose accessories from the right panel</span>'}</div></div>`;}
function saveBuild(){if(!state.base)return alert('Choose a firearm first.');const builds=JSON.parse(localStorage.getItem('gac-builds')||'[]');builds.unshift({id:Date.now(),created:new Date().toLocaleString(),base:state.base,selections:Object.values(state.selections).filter(Boolean)});localStorage.setItem('gac-builds',JSON.stringify(builds));alert('Build saved on this device.');}
$('#saveBuildButton').addEventListener('click',saveBuild);
function renderSaved(){const builds=JSON.parse(localStorage.getItem('gac-builds')||'[]');$('#savedBuilds').innerHTML=builds.length?builds.map(b=>`<article class="saved-card"><p class="eyebrow">${b.base.manufacturer}</p><h3>${b.base.model}</h3><p>${b.created}</p><p>${b.selections.map(x=>x.name).join(' · ')||'Base firearm only'}</p><div class="saved-actions"><button class="small-btn" onclick="loadBuild(${b.id})">Open</button><button class="small-btn" onclick="deleteBuild(${b.id})">Delete</button></div></article>`).join(''):'<p style="color:#98a1a9">No saved builds yet.</p>';}
window.loadBuild=id=>{const b=JSON.parse(localStorage.getItem('gac-builds')||'[]').find(x=>x.id===id);if(!b)return;state={base:b.base,category:null,selections:Object.fromEntries(b.selections.map(p=>[p.category,p]))};showView('builder');$('#baseFirearmSelect').value=b.base.id;renderBuilder();};
window.deleteBuild=id=>{const builds=JSON.parse(localStorage.getItem('gac-builds')||'[]').filter(x=>x.id!==id);localStorage.setItem('gac-builds',JSON.stringify(builds));renderSaved();};
const dialog=$('#quoteDialog');function openQuote(){dialog.showModal()}$('#quoteButton').addEventListener('click',openQuote);$('#buildQuoteButton').addEventListener('click',openQuote);$('#prepareQuote').addEventListener('click',e=>{e.preventDefault();const t=totals();const text=`GAC BUILD QUOTE REQUEST\nName: ${$('#quoteName').value||'Not provided'}\nEmail: ${$('#quoteEmail').value||'Not provided'}\nBase: ${state.base?state.base.manufacturer+' '+state.base.model:'No build selected'}\nAccessories: ${t.selected.map(p=>p.name).join(', ')||'None'}\nEstimated total: $${t.price.toLocaleString()}\nNotes: ${$('#quoteNotes').value||'None'}\n\nAll configurations require compatibility and legal review before fulfillment.`;$('#quoteOutput').textContent=text;$('#quoteOutput').style.display='block';});
['searchInput','platformFilter','manufacturerFilter'].forEach(id=>$('#'+id).addEventListener('input',renderCatalog));
populateFilters();renderCatalog();setupBuilder();
