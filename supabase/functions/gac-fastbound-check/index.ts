import { createFastBoundCheckHandler } from './handler.mjs';

Deno.serve(createFastBoundCheckHandler({ env: (name: string) => Deno.env.get(name) }));
