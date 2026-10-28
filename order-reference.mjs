export function formatOrderReference(order){
 const number=order?.customer_order_number;
 if(number==null&&!/^\d+$/.test(String(order?.order_number||'')))return String(order?.order_number||'');
 const id=String(order?.id||'').replace(/[^a-f\d]/gi,'').toUpperCase();
 if(id.length>=12)return 'AK'+id.slice(0,12);
 return String(order?.order_number||number||'');
}
