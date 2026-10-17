import {createExpiryHandler} from './handler.mjs';Deno.serve(createExpiryHandler({env:name=>Deno.env.get(name)}));
