const models=[
{id:'standard',name:'GAC-15 Standard',caliber:'5.56 NATO',barrel:'16 in',weight:7.0,price:1199,image:'assets/build-1.jpg'},
{id:'recon',name:'GAC-15 Recon',caliber:'5.56 NATO',barrel:'14.5 / 16 in',weight:7.3,price:1499,image:'assets/build-2.jpg'},
{id:'dmr',name:'GAC-15 DMR',caliber:'5.56 / 6.5',barrel:'18 in',weight:8.2,price:1799,image:'assets/build-3.jpg'},
{id:'pistol',name:'GAC-15 Pistol',caliber:'5.56 NATO',barrel:'10.5 / 11.5 in',weight:6.4,price:999,image:'assets/build-4.jpg'}
];
const groups={
'Barrel / Handguard':[
{name:'16 in M-LOK',price:0,img:'assets/handguard-1.jpg',visual:'assets/builder-standard.jpg'},
{name:'14.5 in M-LOK',price:95,img:'assets/handguard-2.jpg',visual:'assets/build-2.jpg'},
{name:'18 in M-LOK',price:165,img:'assets/handguard-3.jpg',visual:'assets/build-3.jpg'},
{name:'10.5 in Compact',price:-90,img:'assets/handguard-4.jpg',visual:'assets/build-4.jpg'}],
'Optic':[
{name:'Holosun-style Red Dot',price:329,img:'assets/optic-1.jpg',visual:'assets/builder-standard.jpg'},
{name:'Enclosed Reflex',price:469,img:'assets/optic-2.jpg',visual:'assets/build-2.jpg'},
{name:'LPVO Setup',price:599,img:'assets/optic-3.jpg',visual:'assets/build-3.jpg'},
{name:'No Optic',price:0,img:'assets/optic-4.jpg',visual:'assets/build-1.jpg'}],
'Stock':[
{name:'CTR-style Stock',price:0,img:'assets/stock-1.jpg',visual:'assets/builder-standard.jpg'},
{name:'SOPMOD-style Stock',price:45,img:'assets/stock-2.jpg',visual:'assets/build-2.jpg'},
{name:'SL-style Stock',price:30,img:'assets/stock-3.jpg',visual:'assets/build-1.jpg'},
{name:'Precision Stock',price:180,img:'assets/stock-4.jpg',visual:'assets/build-3.jpg'}],
'Grip':[
{name:'MOE+ style Grip',price:0,img:'assets/grip-1.jpg'},
{name:'Mod 3 style Grip',price:18,img:'assets/grip-2.jpg'},
{name:'K2 style Grip',price:15,img:'assets/grip-3.jpg'},
{name:'Vertical-angle Grip',price:25,img:'assets/grip-4.jpg'}],
'Muzzle Device':[
{name:'A2-style Flash Hider',price:0,img:'assets/muzzle-1.jpg'},
{name:'Compensator',price:129,img:'assets/muzzle-2.jpg'},
{name:'Hybrid Brake',price:159,img:'assets/muzzle-3.jpg'},
{name:'Suppressor-ready Mount',price:179,img:'assets/muzzle-4.jpg'}],
'Magazine':[
{name:'30-round Style',price:0,img:'assets/mag-1.jpg'},
{name:'Lancer-style',price:22,img:'assets/mag-2.jpg'},
{name:'Gen 2 Polymer Style',price:18,img:'assets/mag-3.jpg'},
{name:'20-round Style',price:16,img:'assets/mag-4.jpg'}]
};
let state={model:models[0],category:Object.keys(groups)[0],selections:{}};
const $=s=>document.querySelector(s), $$=s=>[...document.querySelectorAll(s)];
function showView(id){$$('.view').forEach(v=>v.classList.toggle('active',v.id===id));window.scrollTo({top:0,behavior:'smooth'});if(id==='builder')renderBuilder();}
$$('[data-view]').forEach(b=>b.addEventListener('click',()=>showView(b.dataset.view)));
function modelCard(m){return `<article class="model-card" onclick="chooseModel('${m.id}',true)"><img src="${m.image}" alt="${m.name}"><div class="model-body"><p class="eyebrow">GASSETT ARMS COMPANY</p><h3>${m.name}</h3><p>${m.caliber} · ${m.barrel}</p><div class="model-bottom"><strong>$${m.price.toLocaleString()}</strong><span>Configure →</span></div></div></article>`}
$('#modelGrid').innerHTML=models.map(modelCard).join('');$('#firearmsGrid').innerHTML=models.map(modelCard).join('');
window.chooseModel=(id,go=false)=>{state.model=models.find(m=>m.id===id)||models[0];state.selections={};if(go)showView('builder');renderBuilder();}
function total(){return state.model.price+Object.values(state.selections).filter(Boolean).reduce((n,p)=>n+p.price,0)}
function currentVisual(){const picks=Object.values(state.selections).filter(Boolean).reverse();return picks.find(p=>p.visual)?.visual || (state.model.id==='standard'?'assets/builder-standard.jpg':state.model.image)}
function renderBuilder(){
$('#platformCards').innerHTML=models.map(m=>`<button class="platform-card ${m.id===state.model.id?'active':''}" onclick="chooseModel('${m.id}')"><img src="${m.image}" alt=""><strong>${m.name}</strong><small>$${m.price.toLocaleString()}</small></button>`).join('');
$('#categoryTabs').innerHTML=`<div class="category-tabs">${Object.keys(groups).map(c=>`<button class="${c===state.category?'active':''}" onclick="setCategory('${c.replaceAll("'","\\'")}')">${c}</button>`).join('')}</div>`;
$('#partOptions').innerHTML=`<div class="option-grid">${groups[state.category].map((p,i)=>`<button class="part-card ${state.selections[state.category]?.name===p.name?'selected':''}" onclick="pickPart(${i})"><img src="${p.img}" alt="${p.name}"><h4>${p.name}</h4><p>${state.category}</p><div class="part-price"><span>${p.price===0?'Included':(p.price>0?'+$'+p.price:'-$'+Math.abs(p.price))}</span><b>${state.selections[state.category]?.name===p.name?'SELECTED':'SELECT'}</b></div></button>`).join('')}</div>`;
const img=$('#builderImage');img.src=currentVisual();$('.rifle-frame').classList.remove('pulse');requestAnimationFrame(()=>{$('.rifle-frame').classList.add('pulse');setTimeout(()=>$('.rifle-frame').classList.remove('pulse'),240)});
$('#previewLabel').textContent=state.model.name;$('#specCaliber').textContent=state.model.caliber;$('#specBarrel').textContent=state.selections['Barrel / Handguard']?.name.split(' M-LOK')[0]||state.model.barrel;$('#specWeight').textContent=(state.model.weight+Object.values(state.selections).filter(Boolean).length*.08).toFixed(1)+' lb est.';$('#specTotal').textContent='$'+total().toLocaleString();
const picks=Object.entries(state.selections).filter(([,v])=>v);$('#selectionSummary').innerHTML=picks.length?picks.map(([k,v])=>`<div class="selection-chip"><span>${k}</span><b>${v.name}</b></div>`).join(''):'<div class="selection-chip"><span>Configuration</span><b>Base rifle</b></div>';
}
window.setCategory=c=>{state.category=c;renderBuilder()};window.pickPart=i=>{const p=groups[state.category][i];state.selections[state.category]=state.selections[state.category]?.name===p.name?null:p;renderBuilder()};
$('#resetBuild').addEventListener('click',()=>{state.selections={};renderBuilder()});
$('#saveBuild').addEventListener('click',()=>{localStorage.setItem('gac-current-build',JSON.stringify({model:state.model.id,selections:state.selections}));const t=document.createElement('div');t.className='saved-toast';t.textContent='Build saved on this device';document.body.appendChild(t);setTimeout(()=>t.remove(),1800)});
const dialog=$('#quoteDialog');function openQuote(){const lines=Object.entries(state.selections).filter(([,v])=>v).map(([k,v])=>`${k}: ${v.name}`);$('#quoteSummary').textContent=`${state.model.name}\n${state.model.caliber} · ${state.model.barrel}\n${lines.join('\n')||'Base configuration'}\nEstimated total: $${total().toLocaleString()}`;dialog.showModal()}
$('#quoteTop').addEventListener('click',openQuote);$('#quoteBuild').addEventListener('click',openQuote);
const saved=JSON.parse(localStorage.getItem('gac-current-build')||'null');if(saved){state.model=models.find(m=>m.id===saved.model)||models[0];state.selections=saved.selections||{}}
renderBuilder();
