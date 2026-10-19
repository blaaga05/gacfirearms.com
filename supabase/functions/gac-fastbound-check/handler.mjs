const FALLBACK_ORIGIN = 'https://gacfirearms.com';

export function createFastBoundCheckHandler({ env, fetcher = fetch }) {
  return async (req) => {
    const origin = env('GAC_SITE_ORIGIN') || FALLBACK_ORIGIN;
    const headers = {
      'Content-Type': 'application/json',
      'Cache-Control': 'no-store',
      'Access-Control-Allow-Origin': origin,
      'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
      'Vary': 'Origin',
    };
    const reply = (body, status = 200) => new Response(JSON.stringify(body), { status, headers });

    if (req.headers.get('origin') && req.headers.get('origin') !== origin) return reply({ error: 'Origin not allowed' }, 403);
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    if (req.method !== 'POST') return reply({ error: 'POST required' }, 405);

    const authorization = req.headers.get('authorization') || '';
    if (!/^Bearer \S+$/.test(authorization)) return reply({ error: 'Sign in required' }, 401);
    const supabaseUrl = env('SUPABASE_URL');
    const publishableKey = env('SUPABASE_ANON_KEY') || (() => {
      try { return JSON.parse(env('SUPABASE_PUBLISHABLE_KEYS') || '{}').default; } catch { return ''; }
    })();
    if (!supabaseUrl || !publishableKey) return reply({ error: 'GAC authentication is not configured' }, 503);

    try {
      const authHeaders = { apikey: publishableKey, Authorization: authorization };
      const userResponse = await fetcher(supabaseUrl + '/auth/v1/user', {
        headers: authHeaders,
        signal: AbortSignal.timeout(10000),
      });
      if (!userResponse.ok) return reply({ error: 'Sign in again' }, 401);
      const ownerResponse = await fetcher(supabaseUrl + '/rest/v1/rpc/gac_is_owner', {
        method: 'POST',
        headers: { ...authHeaders, 'Content-Type': 'application/json' },
        body: '{}',
        signal: AbortSignal.timeout(10000),
      });
      if (!ownerResponse.ok || await ownerResponse.json() !== true) return reply({ error: 'Owner access required' }, 403);

      const account = env('FASTBOUND_ACCOUNT_NUMBER')?.trim();
      const apiKey = env('FASTBOUND_API_KEY')?.trim();
      if (!account || !apiKey) return reply({ error: 'FastBound credentials are not configured in the GAC Website project' }, 503);
      if (!/^\d{1,20}$/.test(account)) return reply({ error: 'FastBound account configuration is invalid' }, 503);

      const response = await fetcher('https://cloud.fastbound.com/' + encodeURIComponent(account) + '/api/Account', {
        method: 'GET',
        headers: {
          Authorization: 'Basic ' + btoa(account + ':' + apiKey),
          Accept: 'application/json',
        },
        signal: AbortSignal.timeout(10000),
      });
      if (!response.ok) {
        await response.body?.cancel();
        return reply({ error: 'FastBound rejected the connection check. Verify the account number and API key in GAC Website secrets.' }, 502);
      }
      await response.body?.cancel();
      return reply({ connected: true, message: 'GAC Website is connected to FastBound.' });
    } catch {
      return reply({ error: 'The connection check could not finish. Try again shortly.' }, 502);
    }
  };
}
