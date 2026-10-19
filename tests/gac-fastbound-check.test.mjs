import test from 'node:test';
import assert from 'node:assert/strict';
import { createFastBoundCheckHandler } from '../supabase/functions/gac-fastbound-check/handler.mjs';

const token = 'Bearer signed-in-session';
const envOf = (extra = {}) => (name) => ({
  GAC_SITE_ORIGIN: 'https://gacfirearms.com',
  SUPABASE_URL: 'https://gac.example.supabase.co',
  SUPABASE_ANON_KEY: 'public-key',
  FASTBOUND_ACCOUNT_NUMBER: '123456',
  FASTBOUND_API_KEY: 'private-key',
  ...extra,
}[name]);
const json = (body, status = 200) => new Response(JSON.stringify(body), { status });

test('requires an authenticated owner before contacting FastBound', async () => {
  const calls = [];
  const handler = createFastBoundCheckHandler({ env: envOf(), fetcher: async (url) => {
    calls.push(url);
    return url.endsWith('/auth/v1/user') ? json({ id: 'owner' }) : json(false);
  } });
  const response = await handler(new Request('https://gac.example/functions/v1/gac-fastbound-check', { method: 'POST', headers: { authorization: token } }));
  assert.equal(response.status, 403);
  assert.deepEqual(calls, ['https://gac.example.supabase.co/auth/v1/user', 'https://gac.example.supabase.co/rest/v1/rpc/gac_is_owner']);
});

test('checks FastBound with server-side credentials after owner verification', async () => {
  const calls = [];
  const handler = createFastBoundCheckHandler({ env: envOf(), fetcher: async (url, options = {}) => {
    calls.push({ url, options });
    if (url.endsWith('/auth/v1/user')) return json({ id: 'owner' });
    if (url.endsWith('/rest/v1/rpc/gac_is_owner')) return json(true);
    return new Response('{}', { status: 200 });
  } });
  const response = await handler(new Request('https://gac.example/functions/v1/gac-fastbound-check', { method: 'POST', headers: { authorization: token, origin: 'https://gacfirearms.com' } }));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { connected: true, message: 'GAC Website is connected to FastBound.' });
  assert.equal(calls.length, 3);
  assert.equal(calls[2].options.method, 'GET');
  assert.equal(calls[2].options.headers.Authorization, 'Basic MTIzNDU2OnByaXZhdGUta2V5');
});

test('rejects unrelated site origins and does not issue an API call', async () => {
  let called = false;
  const handler = createFastBoundCheckHandler({ env: envOf(), fetcher: async () => { called = true; return json({}); } });
  const response = await handler(new Request('https://gac.example/functions/v1/gac-fastbound-check', { method: 'POST', headers: { origin: 'https://attacker.example', authorization: token } }));
  assert.equal(response.status, 403);
  assert.equal(called, false);
});

test('does not return FastBound credentials or account payload', async () => {
  const handler = createFastBoundCheckHandler({ env: envOf(), fetcher: async (url) =>
    url.endsWith('/auth/v1/user') ? json({ id: 'owner' }) : url.endsWith('/rest/v1/rpc/gac_is_owner') ? json(true) : json({ serialNumber: 'SENSITIVE' })
  });
  const response = await handler(new Request('https://gac.example/functions/v1/gac-fastbound-check', { method: 'POST', headers: { authorization: token } }));
  const body = await response.text();
  assert.equal(response.status, 200);
  assert.equal(body.includes('SENSITIVE'), false);
  assert.equal(body.includes('private-key'), false);
});
