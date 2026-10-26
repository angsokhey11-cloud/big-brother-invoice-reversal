'use strict';
// Pure BIG BROTHER settlement calculation. No database writes.
// Amounts use integer USD cents / integer KHR riel; FX requires separately approved flow.
const precision=c=>c==='USD'?2:c==='KHR'?0:(()=>{throw Error('Invalid currency')})();
function parseAmount(input,c){
 const s=String(input).trim(),p=precision(c);
 if(!/^\d+(?:\.\d+)?$/.test(s))throw Error('Invalid amount');
 const [w,f='']=s.split('.');
 if(f.length>p && /[1-9]/.test(f.slice(p)))throw Error('Excess precision');
 const n=BigInt(w)*10n**BigInt(p)+BigInt(f.slice(0,p).padEnd(p,'0')||'0');
 if(n>BigInt(Number.MAX_SAFE_INTEGER))throw Error('Amount too large');
 return Number(n);
}
function formatAmount(n,c){const p=precision(c),base=10**p;if(!Number.isSafeInteger(n)||n<0)throw Error('Invalid units');return p?`${Math.floor(n/base)}.${String(n%base).padStart(p,'0')}`:String(n)}
function allocate({invoiceAmount,invoiceCurrency,mode,selections}){
 if(!['BANK','CASH_BANK','PARTIAL_BANK'].includes(mode))throw Error('Unsupported mode');
 if(!Array.isArray(selections))throw Error('Selections required');
 const target=parseAmount(invoiceAmount,invoiceCurrency),ids=new Set();let used=0;
 const allocations=selections.map(x=>{
  if(!x||!['BANK_REGISTER','CUSTOMER_CREDIT'].includes(x.sourceType)||!x.sourceId)throw Error('Invalid source');
  const id=x.sourceType+':'+x.sourceId;if(ids.has(id))throw Error('Duplicate source');ids.add(id);
  if(x.currency!==invoiceCurrency)throw Error('FX requires separate approval');
  const n=parseAmount(x.useAmount,x.currency),available=parseAmount(x.availableAmount,x.currency);
  if(n<=0||n>available)throw Error('Allocation exceeds balance');
  used+=n;if(!Number.isSafeInteger(used)||used>target)throw Error('Invoice overallocated');
  return {sourceType:x.sourceType,sourceId:x.sourceId,currency:x.currency,amount:formatAmount(n,x.currency)};
 });
 return {currency:invoiceCurrency,mode,invoiceTotal:formatAmount(target,invoiceCurrency),applied:formatAmount(used,invoiceCurrency),remaining:formatAmount(target-used,invoiceCurrency),allocations};
}
function salesmanCashToRemit({cashCollected,currency,refunds}){
 if(!Array.isArray(refunds))throw Error('Refunds required');
 let total=parseAmount(cashCollected,currency);const seen=new Set();
 for(const r of refunds){
  if(!r.id||seen.has(r.id))throw Error('Duplicate refund');seen.add(r.id);
  if(r.currency!==currency||r.status!=='APPROVED'||r.fundingSource!=='SALESMAN_COLLECTION')throw Error('Refund not eligible');
  total-=parseAmount(r.amount,currency);
  if(total<0)throw Error('Refund exceeds selected cash');
 }
 return formatAmount(total,currency);
}
module.exports={parseAmount,formatAmount,allocate,salesmanCashToRemit};
