import {createWebhookHandler} from './handler.mjs';
Deno.serve(createWebhookHandler({env:(name:string)=>Deno.env.get(name)}));
