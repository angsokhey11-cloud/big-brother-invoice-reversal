/* BIG BROTHER — Reversal History Mobile Controller */
(function(){
'use strict';

const frame=document.getElementById('historyFrame');
const boot=document.getElementById('boot');
const bootCard=document.getElementById('bootCard');
const PERMISSION_KEY='route.reversal-history';

const key=v=>String(v||'').trim().toLowerCase();

function showError(message){
  boot.classList.remove('hide');
  bootCard.innerHTML='Could not open Reversal History<div id="bootSub" style="margin-top:6px;color:#718197;font-size:10px;font-weight:600;line-height:1.45">'+String(message||'Unknown error').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]))+'</div>';
  frame.style.display='none';
}

async function assertPermission(win){
  const A=win.BBInvoiceReversalAdapter;
  if(!A?.accessProfile)throw new Error('Invoice Reversal adapter did not load.');
  const profile=await A.accessProfile();
  if(profile?.user?.isAdmin===true)return true;
  const modules=Array.isArray(profile?.modules)?profile.modules:[];
  const grant=modules.find(x=>key(x.moduleKey)==='*')||modules.find(x=>key(x.moduleKey)===PERMISSION_KEY);
  if(!grant||grant.canView!==true)throw new Error('You do not have permission to view Reversal History.');
  return true;
}

function addMobileCss(doc){
  if(doc.getElementById('bb-reversal-history-mobile-css'))return;
  const link=doc.createElement('link');
  link.id='bb-reversal-history-mobile-css';
  link.rel='stylesheet';
  link.href='mobile-history.css?v=20260915-1';
  doc.head.appendChild(link);
}

function setupFilterSheet(doc){
  const filters=doc.querySelector('.filters');
  if(!filters)return;
  const card=filters.closest('.card');
  if(!card)return;
  card.classList.add('bb-filter-card');

  const title=card.querySelector('.card-title');
  if(title&&!doc.getElementById('bbHistoryFilterTrigger')){
    const trigger=doc.createElement('button');
    trigger.type='button';
    trigger.id='bbHistoryFilterTrigger';
    trigger.className='bb-filter-trigger';
    trigger.textContent='☷ Filters';
    title.appendChild(trigger);
  }

  let backdrop=doc.getElementById('bbHistoryFilterBackdrop');
  if(!backdrop){
    backdrop=doc.createElement('div');
    backdrop.id='bbHistoryFilterBackdrop';
    backdrop.className='bb-filter-backdrop';
    doc.body.appendChild(backdrop);
  }

  const body=card.querySelector('.card-body');
  if(body&&!body.querySelector('.bb-filter-sheet-head')){
    const head=doc.createElement('div');
    head.className='bb-filter-sheet-head';
    head.innerHTML='<div><strong>Filter Reversal History</strong><span>Date, invoice number and reversal type</span></div><button type="button" class="bb-filter-close" aria-label="Close filters">×</button>';
    body.insertBefore(head,body.firstChild);
  }

  const open=()=>{card.classList.add('bb-open');backdrop.classList.add('show')};
  const close=()=>{card.classList.remove('bb-open');backdrop.classList.remove('show')};
  const trigger=doc.getElementById('bbHistoryFilterTrigger');
  if(trigger)trigger.onclick=open;
  backdrop.onclick=close;
  const closeBtn=body?.querySelector('.bb-filter-close');
  if(closeBtn)closeBtn.onclick=close;

  ['searchBtn','resetBtn'].forEach(id=>{
    const btn=doc.getElementById(id);
    if(btn&&!btn.dataset.bbMobileClose){
      btn.dataset.bbMobileClose='1';
      btn.addEventListener('click',()=>setTimeout(close,80));
    }
  });
}

function setupHistoryCards(doc){
  const table=doc.querySelector('.history-table');
  const card=table?.closest('.card');
  if(card)card.classList.add('bb-history-card');
}

function setupBackButton(doc){
  const back=doc.getElementById('backBtn');
  if(!back||back.dataset.bbMobileBound)return;
  back.dataset.bbMobileBound='1';
  back.addEventListener('click',event=>{
    event.preventDefault();
    event.stopImmediatePropagation();
    location.href='mobile.html?embed=1&v=20260915-1';
  },true);
}

function wrapAndFitPreview(doc){
  const modal=doc.getElementById('previewModal');
  const body=doc.getElementById('modalBody');
  if(!modal||!body||!modal.classList.contains('open'))return;
  if(body.querySelector('.loading')&&!body.querySelector('.preview-title'))return;

  let stage=body.querySelector(':scope > .bb-preview-stage');
  let paper=stage?.querySelector(':scope > .bb-preview-paper');

  if(!stage||!paper){
    const nodes=[...body.childNodes];
    if(!nodes.length)return;
    stage=doc.createElement('div');
    stage.className='bb-preview-stage';
    paper=doc.createElement('div');
    paper.className='bb-preview-paper';
    nodes.forEach(node=>paper.appendChild(node));
    stage.appendChild(paper);
    body.appendChild(stage);
  }

  const BASE_WIDTH=794;
  const available=Math.max(260,body.clientWidth-2);
  const scale=Math.min(1,available/BASE_WIDTH);
  stage.style.setProperty('--bb-preview-scale',String(scale));
  const naturalHeight=Math.max(paper.offsetHeight,paper.scrollHeight,1);
  stage.style.width=Math.ceil(BASE_WIDTH*scale)+'px';
  stage.style.height=Math.ceil(naturalHeight*scale)+'px';
  stage.style.marginLeft='auto';
  stage.style.marginRight='auto';
}

function watchPreview(doc,win){
  const modal=doc.getElementById('previewModal');
  const body=doc.getElementById('modalBody');
  if(!modal||!body||modal.dataset.bbMobileWatch)return;
  modal.dataset.bbMobileWatch='1';

  let timer=null;
  const run=()=>{
    clearTimeout(timer);
    timer=setTimeout(()=>{
      win.requestAnimationFrame(()=>wrapAndFitPreview(doc));
      setTimeout(()=>wrapAndFitPreview(doc),140);
      setTimeout(()=>wrapAndFitPreview(doc),420);
    },35);
  };

  new win.MutationObserver(run).observe(modal,{attributes:true,attributeFilter:['class']});
  new win.MutationObserver(run).observe(body,{childList:true,subtree:false});
  win.addEventListener('resize',()=>wrapAndFitPreview(doc));
}

function watchRows(doc,win){
  const rows=doc.getElementById('historyRows');
  if(!rows||rows.dataset.bbMobileWatch)return;
  rows.dataset.bbMobileWatch='1';
  new win.MutationObserver(()=>setupHistoryCards(doc)).observe(rows,{childList:true,subtree:true});
}

function inject(doc,win){
  addMobileCss(doc);
  setupFilterSheet(doc);
  setupHistoryCards(doc);
  setupBackButton(doc);
  watchPreview(doc,win);
  watchRows(doc,win);
  setTimeout(()=>wrapAndFitPreview(doc),150);
}

frame.addEventListener('load',async()=>{
  try{
    const win=frame.contentWindow;
    const doc=frame.contentDocument||win.document;
    if(!doc?.head||!doc?.body)throw new Error('Reversal History page could not be loaded.');
    await assertPermission(win);
    inject(doc,win);
    setTimeout(()=>inject(doc,win),300);
    setTimeout(()=>inject(doc,win),900);
    frame.style.display='block';
    boot.classList.add('hide');
  }catch(error){
    console.error('Reversal History Mobile:',error);
    showError(error?.message||error);
  }
});

})();
