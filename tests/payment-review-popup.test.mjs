import test from 'node:test';
import assert from 'node:assert/strict';
import {mountHostedCheckout} from '../web/hosted-checkout.mjs';
class Element{constructor(tag='div'){this.tag=tag;this.children=[];this.style={};this.nodes={};this.open=false;}append(...nodes){this.children.push(...nodes)}prepend(...nodes){this.children.unshift(...nodes)}setAttribute(){}addEventListener(){}querySelector(s){return this.nodes[s]??=new Element()}replaceChildren(){this.children=[]}showModal(){this.open=true}close(){this.open=false}focus(){this.focused=true}click(){this.onclick?.()}}
test('unresolved payment opens an acknowledgment popup, links to GAC messages, and clears between accounts',async()=>{
 const globals=['document','sessionStorage','location','setInterval'];const originals=Object.fromEntries(globals.map(k=>[k,globalThis[k]]));
 try{
 const body=new Element(),head=new Element(),purchase=new Element(),messageButton=new Element(),messageBody=new Element();purchase.parentElement=new Element();let opened=false;messageButton.onclick=()=>opened=true;
 globalThis.document={hidden:false,body,head,createElement:t=>new Element(t),getElementById:id=>id==='purchaseNumbers'?purchase:messageBody,querySelector:()=>messageButton};
 globalThis.sessionStorage={getItem:()=>null,setItem(){},removeItem(){}};globalThis.location={search:'',pathname:'/account.html',hash:''};let poll;globalThis.setInterval=fn=>{poll=fn;return 0};
 let alerts=[{transaction_id:'test-reference',collection:'TEST COLLECTION',numbers:[5]}];const ui=mountHostedCheckout({client:{rpc:async name=>({data:name==='gac_my_payment_reviews'?alerts:[],error:null})},mount:new Element(),action:fn=>fn(),status(){},refresh:async()=>{}});
 await ui.sync({user_id:'a'},false);const dialog=body.children.find(n=>n.tag==='dialog');assert.equal(dialog.open,true);const text=dialog.children.map(n=>n.textContent).join(' ');assert.match(text,/Do not buy another number or pay again/);assert.match(text,/has not secured/);assert.match(text,/Numbers 5/);assert.equal(dialog.children.at(-1).focused,true);
 dialog.children.find(n=>n.textContent==='Message GAC').click();assert.equal(opened,true);assert.equal(dialog.open,false);await ui.sync({user_id:'a'},false);assert.equal(dialog.open,false,'Polling must not reopen an acknowledged review');
 ui.clear();alerts=[];await ui.sync({user_id:'b'},false);assert.equal(dialog.open,false,'No alert leaks to the next account');assert.equal(typeof poll,'function');
 }finally{for(const key of globals)if(originals[key]===undefined)delete globalThis[key];else globalThis[key]=originals[key];}
});
