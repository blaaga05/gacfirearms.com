import {createMerchHandler} from './handler.mjs';Deno.serve(createMerchHandler({env:name=>Deno.env.get(name)}));
