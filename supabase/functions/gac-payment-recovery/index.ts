import {createRecoveryHandler} from './handler.mjs';
Deno.serve(createRecoveryHandler({env:(name:string)=>Deno.env.get(name)}));
