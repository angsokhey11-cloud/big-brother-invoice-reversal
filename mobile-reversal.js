/* BIG BROTHER — Invoice Reversal Mobile Controller V1 */
(function(){
'use strict';

const SUPABASE_URL='https://sjfhlaclgmkwwofzstok.supabase.co';
const SUPABASE_KEY='sb_publishable_w762jR65CWwlO30fKQsYOw_6L9grx8S';
const SESSION_KEY='BB_SUPABASE_DEV_SESSION_V1';
const frame=document.getElementById('reversalFrame');
const boot=document.getElementById('boot');
const bootCard=document.getElementById('bootCard');
let mobileCss='';

function readSession(){try{return JSON.parse(localStorage.getItem(SESSION_KEY)||'null')}catch(_){return null}}
function saveSession(s){try{if(!s){localStorage.removeItem(SESSION_KEY);return}if(!s.expires_at&&s.expires_in)s.expires_at=Math.floor(Date.now()/1000)+Number(s.expires_in);localStorage.setItem(SESSION_KEY,JSON.stringify(s))}catch(_){}}
async function parse(r){const t=await r.text();let d={};try{d=t?JSON.parse(t):{}}catch(_){d={message:t}}if(!r.ok)throw new Error(d.message||d.error_description||d.error||('Request failed ('+r.status+')'));return d}
async function ensureSession(){let s=readSession();if(!s?.access_token)throw new Error('Please sign in to BIG BROTHER first.');if(s.expires_at&&Number(s.expires_at)<Math.floor(Date.now()/1000)+45){if(!s.refresh_token)throw new Error('Your BIG BROTHER session has expired.');const r=await fetch(SUPABASE_URL+'/auth/v1/token?grant_type=refresh_token',{method:'POST',headers:{apikey:SUPABASE_KEY,'Content-Type':'application/json'},body:JSON.stringify({refresh_token:s.refresh_token}),cache:'no-store'});s=await parse(r);saveSession(s)}return s}
async function rpc(fn,args={}){let s=await ensureSession();const call=token=>fetch(SUPABASE_URL+'/rest/v1/rpc/'+fn,{method:'POST',headers:{apikey:SUPABASE_KEY,Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify(args||{}),cache:'no-store'});let r=await call(s.access_token);if(r.status===401){s=await ensureSession();r=await call(s.access_token)}return parse(r)}
const key=v=>String(v||'').trim().toLowerCase();

async function assertPermission(){
  const profile=await rpc('bb_current_access_profile');
  if(profile?.user?.isAdmin===true)return profile;
  const modules=Array.isArray(profile?.modules)?profile.modules:[];
  const grant=modules.find(x=>key(x.moduleKey)==='*')||modules.find(x=>key(x.moduleKey)==='route.sale-return');
  if(!grant||grant.canView!==true)throw new Error('You do not have permission to use Invoice Reversal.');
  return profile;
}

function esc(v){return String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]))}
function showError(error){
  if(bootCard)bootCard.innerHTML='Could not open Invoice Reversal<div class="bb-sub">'+esc(error?.message||error)+'</div>';
}

function childDoc(){try{return frame.contentDocument||frame.contentWindow.document}catch(_){return null}}

function injectCss(doc){
  if(!doc?.head)return;
  let style=doc.getElementById('bbMobileReversalSkin');
  if(!style){style=doc.createElement('style');style.id='bbMobileReversalSkin';doc.head.appendChild(style)}
  style.textContent=mobileCss;
}

function polishMobile(doc){
  const title=doc.querySelector('.brand h1');
  if(title)title.textContent='↩️ Invoice Reversal';
  const load=doc.getElementById('loadInvoiceBtn');
  if(load)load.innerHTML='🔎 Load';
  const refresh=doc.getElementById('refreshInvoicesBtn');
  if(refresh)refresh.textContent='↻ Refresh';

  const invoiceCard=doc.getElementById('invoiceCard');
  if(invoiceCard&&!invoiceCard.dataset.bbMobileWatch){
    invoiceCard.dataset.bbMobileWatch='1';
    new frame.contentWindow.MutationObserver(()=>{
      if(!invoiceCard.classList.contains('hidden')){
        setTimeout(()=>invoiceCard.scrollIntoView({behavior:'smooth',block:'start'}),80);
      }
    }).observe(invoiceCard,{attributes:true,attributeFilter:['class']});
  }
}

function ensureReceiptStage(doc){
  const dialog=doc.querySelector('#receiptModal .receipt-dialog');
  const body=doc.getElementById('receiptBody');
  const actions=doc.querySelector('#receiptModal .receipt-actions');
  if(!dialog||!body)return null;

  let scroll=dialog.querySelector('.bb-reversal-receipt-scroll');
  let stage=dialog.querySelector('.bb-reversal-receipt-stage');
  if(!scroll){
    scroll=doc.createElement('div');
    scroll.className='bb-reversal-receipt-scroll';
    if(actions)dialog.insertBefore(scroll,actions);else dialog.appendChild(scroll);
  }
  if(!stage){
    stage=doc.createElement('div');
    stage.className='bb-reversal-receipt-stage';
    scroll.appendChild(stage);
  }
  if(body.parentNode!==stage)stage.appendChild(body);
  return {scroll,stage,body};
}

function fitReceipt(doc){
  const modal=doc.getElementById('receiptModal');
  if(!modal||!modal.classList.contains('open'))return;
  const parts=ensureReceiptStage(doc);
  if(!parts)return;
  const BASE_WIDTH=760;
  const available=Math.max(260,parts.scroll.clientWidth-2);
  const scale=Math.min(1,available/BASE_WIDTH);
  parts.stage.style.setProperty('--bb-receipt-scale',String(scale));
  const naturalHeight=Math.max(parts.body.offsetHeight,parts.body.scrollHeight,1);
  parts.stage.style.width=Math.ceil(BASE_WIDTH*scale)+'px';
  parts.stage.style.height=Math.ceil(naturalHeight*scale)+'px';
  parts.stage.style.marginLeft='auto';
  parts.stage.style.marginRight='auto';
}

function watchReceipt(doc){
  const modal=doc.getElementById('receiptModal');
  const body=doc.getElementById('receiptBody');
  if(!modal||!body||modal.dataset.bbMobileReceiptWatch)return;
  modal.dataset.bbMobileReceiptWatch='1';
  ensureReceiptStage(doc);
  const win=frame.contentWindow;
  const refit=()=>{
    win.requestAnimationFrame(()=>fitReceipt(doc));
    setTimeout(()=>fitReceipt(doc),120);
    setTimeout(()=>fitReceipt(doc),360);
  };
  new win.MutationObserver(()=>{if(modal.classList.contains('open'))refit()}).observe(modal,{attributes:true,attributeFilter:['class']});
  new win.MutationObserver(()=>{if(modal.classList.contains('open'))refit()}).observe(body,{childList:true,subtree:true,characterData:true});
  win.addEventListener('resize',()=>fitReceipt(doc));
}

function watchRows(doc){
  const rows=doc.getElementById('productRows');
  if(!rows||rows.dataset.bbMobileObserved)return;
  rows.dataset.bbMobileObserved='1';
  const win=frame.contentWindow;
  new win.MutationObserver(()=>win.requestAnimationFrame(()=>polishMobile(doc))).observe(rows,{childList:true,subtree:true});
}

function enhance(){
  const doc=childDoc();
  if(!doc?.head||!doc?.body)return;
  injectCss(doc);
  polishMobile(doc);
  watchRows(doc);
  watchReceipt(doc);
  frame.style.display='block';
  if(boot)boot.classList.add('hide');
  setTimeout(()=>{polishMobile(doc);fitReceipt(doc)},150);
  setTimeout(()=>{polishMobile(doc);fitReceipt(doc)},650);
}

async function start(){
  try{
    if(bootCard)bootCard.querySelector('.bb-sub').textContent='Checking Invoice Reversal permission';
    await assertPermission();
    mobileCss=await fetch('mobile-reversal.css?v=20260915-1',{cache:'no-store'}).then(r=>{if(!r.ok)throw new Error('Could not load mobile reversal style.');return r.text()});
    frame.addEventListener('load',()=>{setTimeout(enhance,40);setTimeout(enhance,300);setTimeout(enhance,1000)});
    frame.src='index.html?embed=1&mobileSkin=1&v=20260924-invoiceid1';
  }catch(error){
    console.error('Invoice Reversal Mobile:',error);
    showError(error);
  }
}

start();
})();
