import {hostedSettings} from '../gac-hosted-checkout/handler.mjs';
const PAYMENT='https://accept.authorize.net/payment/payment';
export function summarizeHostedPage(html,status){
 if(status!==200)return 'Hosted page returned HTTP '+status;
 const match=html.match(/\bg_errorPanelMessage\s*=\s*"([^\"]*)"/);
 const message=match?.[1]||'';
 if(/technical issue/i.test(message))return 'Authorize.net technical processing error';
 if(/timed? out|expired/i.test(message))return 'Authorize.net reported an expired page';
 if(/invalid|missing/i.test(message))return 'Authorize.net rejected the form token';
 if(message.trim())return 'Authorize.net returned a hosted-form error';
 if(/\bg_merchantData\s*=\s*\{/.test(html)&&/\bg_pageOptions\s*=\s*\{/.test(html))return 'Form data loaded successfully';
 return 'Hosted page did not provide usable form data';
}
export async function diagnoseHosted({env,fetcher=fetch}){
 const authentication={name:env('AUTHORIZENET_API_LOGIN_ID')?.trim(),transactionKey:env('AUTHORIZENET_TRANSACTION_KEY')?.trim()};
 const setting=(settingName,value)=>({settingName,settingValue:JSON.stringify(value)});
 const minimal={setting:[setting('hostedPaymentReturnOptions',{showReceipt:true,url:'https://gacfirearms.com/account.html',cancelUrl:'https://gacfirearms.com/account.html'}),setting('hostedPaymentCustomerOptions',{showEmail:false,requiredEmail:false,addPaymentProfile:false}),setting('hostedPaymentPaymentOptions',{showCreditCard:true,showBankAccount:false,cardCodeRequired:true})]};
 const full=hostedSettings(crypto.randomUUID());
 const variants=[['Minimal form',minimal,'base'],['Minimal form with invoice',minimal,'invoice'],['Updated checkout request',full,'invoice']];
 const results=await Promise.all(variants.map(async([name,options,mode])=>{
  try{
   // Request and load a $1 form without entering any payment information. No
   // transaction-creation API is called and no token is returned to the browser.
   const transactionRequest={transactionType:'authCaptureTransaction',amount:'1.00',...(mode!=='base'?{order:{invoiceNumber:'DIAG'+crypto.randomUUID().replaceAll('-','').slice(0,16)}}:{})};
   const response=await fetcher('https://api.authorize.net/xml/v1/request.api',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({getHostedPaymentPageRequest:{merchantAuthentication:authentication,transactionRequest,hostedPaymentSettings:options}}),signal:AbortSignal.timeout(12000)});
   if(!response.ok)return name+': token request HTTP '+response.status;
   const data=JSON.parse((await response.text()).replace(/^\uFEFF/,''));
   if(data.messages?.resultCode!=='Ok'||typeof data.token!=='string')return name+': Authorize.net rejected the token request';
   const page=await fetcher(PAYMENT,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({token:data.token}).toString(),signal:AbortSignal.timeout(12000)});
   return name+': '+summarizeHostedPage(await page.text(),page.status);
  }catch{return name+': diagnostic could not finish; try again shortly'}
 }));
 return {ok:true,message:results.join('\n')+'\nNo charge was made. No card information was entered or stored.'};
}
