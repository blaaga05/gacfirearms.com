const toggle=document.querySelector('.menu-toggle');
const nav=document.querySelector('.site-nav');
if(toggle&&nav){toggle.addEventListener('click',()=>{const open=nav.classList.toggle('open');toggle.setAttribute('aria-expanded',String(open));document.body.classList.toggle('menu-open',open)});nav.querySelectorAll('a').forEach(a=>a.addEventListener('click',()=>{nav.classList.remove('open');toggle.setAttribute('aria-expanded','false');document.body.classList.remove('menu-open')}));}
const year=document.getElementById('year');if(year)year.textContent=new Date().getFullYear();
const form=document.getElementById('contact-form');
if(form){form.addEventListener('submit',e=>{e.preventDefault();const data=new FormData(form);const recipient=data.get('department');const subject=encodeURIComponent(`GAC website inquiry from ${data.get('name')}`);const body=encodeURIComponent(`Name: ${data.get('name')}\nEmail: ${data.get('email')}\n\nMessage:\n${data.get('message')}`);window.location.href=`mailto:${recipient}?subject=${subject}&body=${body}`;});}
