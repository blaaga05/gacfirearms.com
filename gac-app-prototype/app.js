const firearms=[
{id:'ar15',manufacturer:'GAC',model:'GA-15 Builder Platform',platform:'AR-15',caliber:'5.56 NATO',action:'Semi-auto',price:899,weight:6.4},
{id:'glock19',manufacturer:'Glock',model:'19 Gen 5 MOS',platform:'Pistol',caliber:'9mm',action:'Semi-auto',price:620,weight:1.48},
{id:'sigp365',manufacturer:'SIG Sauer',model:'P365 X-Macro',platform:'Pistol',caliber:'9mm',action:'Semi-auto',price:819,weight:1.35},
{id:'mp15',manufacturer:'Smith & Wesson',model:'M&P15 Sport III',platform:'AR-15',caliber:'5.56 NATO',action:'Semi-auto',price:799,weight:6.8},
{id:'rug556',manufacturer:'Ruger',model:'AR-556',platform:'AR-15',caliber:'5.56 NATO',action:'Semi-auto',price:829,weight:6.5},
{id:'walterpdp',manufacturer:'Walther',model:'PDP Compact',platform:'Pistol',caliber:'9mm',action:'Semi-auto',price:649,weight:1.55}
];
const categories={AR15:['Optic','Stock','Grip','Handguard','Light','Muzzle Device','Finish'],Pistol:['Optic','Light','Magazine','Sights','Finish']};
const parts=[
{id:'o1',category:'Optic',name:'Holosun HS510C',platforms:['AR-15'],price:309,weight:.31,fit:'Confirmed compatible',visual:'redDot'},
{id:'o2',category:'Optic',name:'Vortex Strike Eagle 1-6x',platforms:['AR-15'],price:399,weight:1.15,fit:'Requires compatible mount',visual:'scope'},
{id:'o3',category:'Optic',name:'Trijicon RMR Type 2',platforms:['Pistol'],models:['glock19'],price:499,weight:.08,fit:'MOS plate required',visual:'rmr'},
{id:'o4',category:'Optic',name:'Holosun SCS MOS',platforms:['Pistol'],models:['glock19'],price:349,weight:.08,fit:'Direct MOS fit',visual:'scs'},
{id:'s1',category:'Stock',name:'B5 Systems SOPMOD',platforms:['AR-15'],price:95,weight:.72,fit:'Mil-spec buffer tube',visual:'sopmod'},
{id:'s2',category:'Stock',name:'Magpul CTR',platforms:['AR-15'],price:65,weight:.55,fit:'Mil-spec buffer tube',visual:'ctr'},
{id:'g1',category:'Grip',name:'Magpul MOE-K2',platforms:['AR-15'],price:24,weight:.18,fit:'AR-pattern grip mount',visual:'k2'},
{id:'h1',category:'Handguard',name:'Aero ATLAS R-ONE 15 inch',platforms:['AR-15'],price:229,weight:.85,fit:'AR-15 upper compatible',visual:'longRail'},
{id:'h2',category:'Handguard',name:'BCM MCMR 13 inch',platforms:['AR-15'],price:249,weight:.72,fit:'AR-15 upper compatible',visual:'shortRail'},
{id:'l1',category:'Light',name:'Streamlight ProTac HL-X',platforms:['AR-15'],price:139,weight:.39,fit:'Picatinny/M-LOK mount',visual:'rifleLight'},
{id:'l2',category:'Light',name:'SureFire X300 Turbo',platforms:['Pistol'],models:['glock19'],price:369,weight:.28,fit:'Universal rail fit',visual:'pistolLight'},
{id:'m1',category:'Muzzle Device',name:'SureFire WarComp 1/2x28',platforms:['AR-15'],price:169,weight:.23,fit:'Verify barrel thread pattern',visual:'warcomp'},
{id:'m2',category:'Magazine',name:'Glock OEM 15-round Magazine',platforms:['Pistol'],models:['glock19'],price:30,weight:.18,fit:'Glock 19 Gen 5',visual:'mag'},
{id:'si1',category:'Sights',name:'AmeriGlo GL-429',platforms:['Pistol'],models:['glock19'],price:65,weight:.03,fit:'Glock-compatible dovetail',visual:'sights'},
{id:'f1',category:'Finish',name:'GAC Graphite Finish Preview',platforms:['Pistol','AR-15'],price:225,weight:0,fit:'Visual service preview',visual:'graphite'}
];
let state={base:null,category:null,selections:{}};
const $=s=>document.querySelector(s); const $$=s=>[...document.querySelectorAll(s)];
function showView(id){$$('.view').forEach(v=>v.classList.toggle('active',v.id===id));scrollTo({top:0,behavior:'smooth'});if(id==='saved')renderSaved();}
$$('[data-view]').forEach(b=>b.addEventListener('click',()=>showView(b.dataset.view)));
$$('[data-build-preset]').forEach(b=>b.addEventListener('click',()=>{showView('builder');$('#baseFirearmSelect').value=b.dataset.buildPreset;selectBase(b.dataset.buildPreset)}));

function rifleSVG(selected={},compact=false){
  const optic=selected.Optic?.visual||'none', stock=selected.Stock?.visual||'base', hand=selected.Handguard?.visual||'base', light=selected.Light?.visual||'none', muzzle=selected['Muzzle Device']?.visual||'base', finish=selected.Finish?'graphite':'black';
  const handX=430, handW=hand==='shortRail'?210:hand==='longRail'?285:250;
  return `<svg class="gun-svg ${compact?'mini-svg':''}" data-finish="${finish}" viewBox="0 0 1000 380" role="img" aria-label="GA-15 visual configuration preview">
  <g>
    <rect x="70" y="184" width="150" height="24" rx="5" class="dark"/>
    ${stock==='sopmod'?`<path d="M40 155h155l58 28-31 48H77l-37-26z" class="finish"/>`:
      stock==='ctr'?`<path d="M45 166h150l47 19-28 43H82l-37-22z" class="finish"/>`:
      `<path d="M50 163h145l44 21-25 40H84l-34-19z" class="finish"/>`}
    <rect x="205" y="178" width="95" height="36" rx="4" class="dark"/>
    <path d="M288 150h166v93H284l-24-31v-34z" class="finish"/>
    <rect x="330" y="132" width="122" height="18" rx="4" class="dark"/>
    <path d="M350 240h58l25 95h-50l-44-77z" class="dark"/>
    <path d="M405 236h63l25 112h-61l-38-88z" class="finish"/>
    <rect x="${handX}" y="161" width="${handW}" height="61" rx="6" class="finish"/>
    <rect x="${handX+8}" y="150" width="${handW-5}" height="12" rx="3" class="dark"/>
    ${Array.from({length:hand==='shortRail'?7:9},(_,i)=>`<rect x="${handX+18+i*27}" y="181" width="16" height="7" rx="2" class="slot"/>`).join('')}
    <rect x="${handX+handW}" y="183" width="155" height="8" rx="3" class="detail"/>
    ${muzzle==='warcomp'?`<path d="M${handX+handW+150} 174h55v26h-55v-7h-20v-12h20z" class="finish"/><rect x="${handX+handW+166}" y="178" width="6" height="6" class="slot"/><rect x="${handX+handW+180}" y="178" width="6" height="6" class="slot"/>`:`<rect x="${handX+handW+150}" y="178" width="43" height="18" rx="3" class="dark"/>`}
    ${optic==='redDot'?`<rect x="350" y="99" width="76" height="32" rx="7" class="finish"/><rect x="367" y="88" width="42" height="15" rx="5" class="dark"/><circle cx="389" cy="115" r="10" class="slot"/>`:
      optic==='scope'?`<rect x="315" y="99" width="155" height="20" rx="9" class="finish"/><circle cx="322" cy="109" r="23" class="dark"/><circle cx="463" cy="109" r="27" class="dark"/><rect x="355" y="119" width="10" height="18" class="dark"/><rect x="410" y="119" width="10" height="18" class="dark"/>`:''}
    ${light==='rifleLight'?`<rect x="585" y="221" width="90" height="18" rx="8" class="dark"/><circle cx="673" cy="230" r="14" class="finish"/>`:''}
    <circle cx="305" cy="201" r="5" class="accent-fill"/><text x="306" y="201" fill="#d7d9dc" font-size="16" font-weight="800">GAC</text>
  </g></svg>`;
}

function pistolSVG(selected={},compact=false){
  const optic=selected.Optic?.visual||'none', light=selected.Light?.visual||'none', finish=selected.Finish?'graphite':'black', sights=!!selected.Sights, mag=!!selected.Magazine;
  return `<svg class="gun-svg ${compact?'mini-svg':''}" data-finish="${finish}" viewBox="0 0 760 420" role="img" aria-label="Pistol visual configuration preview">
    <g>
      <path d="M130 128h420l55 34-12 67H176l-46-28z" class="finish"/>
      <path d="M190 227h248l-11 57H350l-18 112H245l-64-150z" class="dark"/>
      <path d="M246 250h75l-6 135h-59z" class="finish"/>
      <rect x="520" y="169" width="100" height="12" rx="4" class="detail"/>
      <rect x="164" y="154" width="34" height="7" class="slot"/><rect x="211" y="154" width="34" height="7" class="slot"/><rect x="258" y="154" width="34" height="7" class="slot"/>
      ${optic==='rmr'?`<path d="M350 89h72l18 39h-108z" class="finish"/><rect x="362" y="101" width="48" height="20" rx="5" class="slot"/>`:
        optic==='scs'?`<path d="M352 94h68l10 34h-90z" class="finish"/><rect x="362" y="105" width="45" height="14" rx="4" class="slot"/>`:''}
      ${light==='pistolLight'?`<rect x="420" y="245" width="105" height="44" rx="8" class="finish"/><circle cx="520" cy="267" r="16" class="detail"/>`:''}
      ${sights?`<rect x="172" y="112" width="22" height="18" class="detail"/><rect x="515" y="111" width="22" height="18" class="detail"/>`:''}
      ${mag?`<path d="M255 367h58l12 42h-78z" class="finish"/>`:''}
      <text x="450" y="196" fill="#d7d9dc" font-size="16" font-weight="800">GAC PREVIEW</text>
    </g></svg>`;
}
function baseSVG(f,selected={},compact=false){return f.platform==='AR-15'?rifleSVG(selected,compact):pistolSVG(selected,compact)}
function partThumb(p){
  const fakeBase=p.platforms[0]==='AR-15'?firearms[0]:firearms[1];
  return baseSVG(fakeBase,{[p.category]:p},true);
}

function populateFilters(){[...new Set(firearms.map(f=>f.manufacturer))].sort().forEach(m=>$('#manufacturerFilter').insertAdjacentHTML('beforeend',`<option>${m}</option>`));}
function renderCatalog(){const q=$('#searchInput').value.toLowerCase();const p=$('#platformFilter').value;const m=$('#manufacturerFilter').value;const list=firearms.filter(f=>(p==='all'||f.platform===p)&&(m==='all'||f.manufacturer===m)&&`${f.manufacturer} ${f.model} ${f.caliber}`.toLowerCase().includes(q));$('#catalogGrid').innerHTML=list.map(f=>`<article class="catalog-card"><div class="catalog-visual">${baseSVG(f,{},true)}</div><div class="catalog-body"><p class="eyebrow">${f.manufacturer}</p><h3>${f.model}</h3><p>${f.platform} · ${f.caliber}</p><div class="spec-row"><span>Starting price</span><strong>$${f.price.toLocaleString()}</strong></div><div class="spec-row"><span>Weight</span><strong>${f.weight} lb</strong></div>${['ar15','glock19'].includes(f.id)?`<button class="primary-btn" onclick="openBuilder('${f.id}')">Customize</button>`:`<button class="small-btn" disabled>Preview only</button>`}</div></article>`).join('')||'<p>No firearms match those filters.</p>';}
window.openBuilder=id=>{showView('builder');$('#baseFirearmSelect').value=id;selectBase(id)};
function setupBuilder(){$('#baseFirearmSelect').innerHTML='<option value="">Choose a firearm...</option>'+firearms.filter(f=>['ar15','glock19'].includes(f.id)).map(f=>`<option value="${f.id}">${f.manufacturer} ${f.model}</option>`).join('');$('#baseFirearmSelect').addEventListener('change',e=>selectBase(e.target.value));}
function selectBase(id){state={base:firearms.find(f=>f.id===id)||null,category:null,selections:{}};renderBuilder();}
function platformKey(){return state.base?.platform==='AR-15'?'AR15':'Pistol'}
function renderBuilder(){if(!state.base){$('#builderTitle').textContent='Build your setup';$('#builderSubtitle').textContent='Choose a base firearm to begin.';$('#categoryButtons').innerHTML='';$('#partsList').innerHTML='';$('#visualStage').innerHTML='<p style="color:#98a1a9">Select a base firearm.</p>';$('#buildTotal').textContent='$0';$('#buildWeight').textContent='Estimated weight: —';return}$('#builderTitle').textContent=`Build: ${state.base.model}`;$('#builderSubtitle').textContent=`${state.base.manufacturer} · ${state.base.caliber}`;const cats=categories[platformKey()];state.category=state.category||cats[0];$('#categoryButtons').innerHTML=cats.map(c=>`<button class="${c===state.category?'active':''}" onclick="selectCategory('${c}')">${c}</button>`).join('');renderParts();renderVisual();}
window.selectCategory=c=>{state.category=c;renderBuilder()};
function compatibleParts(){return parts.filter(p=>p.category===state.category&&p.platforms.includes(state.base.platform)&&(!p.models||p.models.includes(state.base.id)))}
function renderParts(){const available=compatibleParts();$('#partsTitle').textContent=state.category;$('#partsList').innerHTML=available.map(p=>`<article class="part-card ${state.selections[p.category]?.id===p.id?'selected':''}" onclick="togglePart('${p.id}')"><div class="part-thumb">${partThumb(p)}</div><div class="part-info"><h3>${p.name}</h3><p>${p.fit}</p><div class="part-row"><strong>$${p.price}</strong><button class="small-btn" onclick="event.stopPropagation();togglePart('${p.id}')">${state.selections[p.category]?.id===p.id?'Remove':'Select'}</button></div></div></article>`).join('')||'<p style="color:#98a1a9">No verified parts in this prototype category.</p>';}
window.togglePart=id=>{const p=parts.find(x=>x.id===id);state.selections[p.category]=state.selections[p.category]?.id===id?null:p;renderBuilder()};
function totals(){const selected=Object.values(state.selections).filter(Boolean);return{price:(state.base?.price||0)+selected.reduce((s,p)=>s+p.price,0),weight:(state.base?.weight||0)+selected.reduce((s,p)=>s+p.weight,0),selected};}
function renderVisual(){const t=totals();$('#compatibilityBadge').textContent='Compatibility filtered';$('#buildWeight').textContent=`Estimated weight: ${t.weight.toFixed(2)} lb`;$('#buildTotal').textContent=`$${t.price.toLocaleString()}`;$('#visualStage').innerHTML=`<div class="build-preview-wrap"><div class="build-preview">${baseSVG(state.base,state.selections)}</div><div class="preview-caption"><span class="chip">${state.base.manufacturer} ${state.base.model}</span><span class="chip">${state.base.caliber}</span></div><div class="selected-chips">${t.selected.length?t.selected.map(p=>`<span class="chip">${p.category}: ${p.name}</span>`).join(''):'<span class="chip">Choose options to update the preview</span>'}</div></div>`;}
function saveBuild(){if(!state.base)return alert('Choose a firearm first.');const builds=JSON.parse(localStorage.getItem('gac-builds')||'[]');builds.unshift({id:Date.now(),created:new Date().toLocaleString(),base:state.base,selections:Object.values(state.selections).filter(Boolean)});localStorage.setItem('gac-builds',JSON.stringify(builds));alert('Build saved on this device.');}
$('#saveBuildButton').addEventListener('click',saveBuild);
function renderSaved(){const builds=JSON.parse(localStorage.getItem('gac-builds')||'[]');$('#savedBuilds').innerHTML=builds.length?builds.map(b=>`<article class="saved-card"><div class="catalog-visual">${baseSVG(b.base,Object.fromEntries(b.selections.map(p=>[p.category,p])),true)}</div><p class="eyebrow">${b.base.manufacturer}</p><h3>${b.base.model}</h3><p>${b.created}</p><p>${b.selections.map(x=>x.name).join(' · ')||'Base firearm only'}</p><div class="saved-actions"><button class="small-btn" onclick="loadBuild(${b.id})">Open</button><button class="small-btn" onclick="deleteBuild(${b.id})">Delete</button></div></article>`).join(''):'<p style="color:#98a1a9">No saved builds yet.</p>';}
window.loadBuild=id=>{const b=JSON.parse(localStorage.getItem('gac-builds')||'[]').find(x=>x.id===id);if(!b)return;state={base:b.base,category:null,selections:Object.fromEntries(b.selections.map(p=>[p.category,p]))};showView('builder');$('#baseFirearmSelect').value=b.base.id;renderBuilder();};
window.deleteBuild=id=>{const builds=JSON.parse(localStorage.getItem('gac-builds')||'[]').filter(x=>x.id!==id);localStorage.setItem('gac-builds',JSON.stringify(builds));renderSaved();};
const dialog=$('#quoteDialog');function openQuote(){dialog.showModal()}$('#quoteButton').addEventListener('click',openQuote);$('#buildQuoteButton').addEventListener('click',openQuote);$('#prepareQuote').addEventListener('click',e=>{e.preventDefault();const t=totals();const text=`GAC BUILD QUOTE REQUEST\nName: ${$('#quoteName').value||'Not provided'}\nEmail: ${$('#quoteEmail').value||'Not provided'}\nBase: ${state.base?state.base.manufacturer+' '+state.base.model:'No build selected'}\nAccessories: ${t.selected.map(p=>p.name).join(', ')||'None'}\nEstimated total: $${t.price.toLocaleString()}\nNotes: ${$('#quoteNotes').value||'None'}\n\nAll configurations require compatibility, availability, and legal review before fulfillment.`;$('#quoteOutput').textContent=text;$('#quoteOutput').style.display='block';});
['searchInput','platformFilter','manufacturerFilter'].forEach(id=>$('#'+id).addEventListener('input',renderCatalog));
populateFilters();renderCatalog();setupBuilder();
$('#heroBuilderPreview').innerHTML=rifleSVG({Optic:parts.find(p=>p.id==='o1'),Stock:parts.find(p=>p.id==='s1'),Handguard:parts.find(p=>p.id==='h1'),Light:parts.find(p=>p.id==='l1')});
