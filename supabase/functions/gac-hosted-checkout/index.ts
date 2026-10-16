import {createCheckoutHandler} from './handler.mjs';
Deno.serve(createCheckoutHandler({env:(name:string)=>Deno.env.get(name)}));
