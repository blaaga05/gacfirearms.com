import {createAddressSuggestionsHandler} from './handler.mjs';
Deno.serve(createAddressSuggestionsHandler({env:name=>Deno.env.get(name)}));
