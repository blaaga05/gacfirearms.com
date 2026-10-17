import {createChoiceHandler} from './handler.mjs';Deno.serve(createChoiceHandler({env:name=>Deno.env.get(name)}));
