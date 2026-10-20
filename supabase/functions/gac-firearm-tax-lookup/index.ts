import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { normalizeFirearmTaxLookup, normalizeTaxCloudQuote, taxCloudCartPayload } from "../_shared/firearm-tax-lookup.mjs";

const ORIGIN_DEFAULT = "https://gacfirearms.com";
const PREVIEW_ORIGINS = [
  "https://feat-firearm-pricing-config.gacfirearms-com.pages.dev",
  "https://feat-firearm-tax-lookup.gacfirearms-com.pages.dev",
];

Deno.serve(async (req: Request) => {
  const configuredOrigin = Deno.env.get("GAC_SITE_ORIGIN") || ORIGIN_DEFAULT;
  const requestOrigin = req.headers.get("origin") || "";
  const allowedOrigins = new Set([ORIGIN_DEFAULT, configuredOrigin, ...PREVIEW_ORIGINS]);
  const origin = allowedOrigins.has(requestOrigin) ? requestOrigin : configuredOrigin;
  const headers = {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
  const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });
  if (requestOrigin && !allowedOrigins.has(requestOrigin)) return reply({ error: "Origin not allowed" }, 403);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (req.method !== "POST") return reply({ error: "POST required" }, 405);

  const authorization = req.headers.get("authorization") || "";
  if (!/^Bearer \S+$/.test(authorization)) return reply({ error: "Sign in required" }, 401);
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const publishableKey = Deno.env.get("SUPABASE_ANON_KEY") ||
    (() => { try { return JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS") || "{}").default; } catch { return ""; } })();
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !publishableKey || !serviceKey) return reply({ error: "GAC database access is not configured" }, 503);

  try {
    const authHeaders = { apikey: publishableKey, Authorization: authorization };
    const user = await fetch(supabaseUrl + "/auth/v1/user", { headers: authHeaders, signal: AbortSignal.timeout(10000) });
    if (!user.ok) return reply({ error: "Sign in again" }, 401);
    const owner = await fetch(supabaseUrl + "/rest/v1/rpc/gac_is_owner", {
      method: "POST", headers: { ...authHeaders, "Content-Type": "application/json" }, body: "{}",
      signal: AbortSignal.timeout(10000),
    });
    if (!owner.ok || await owner.json() !== true) return reply({ error: "Owner access required" }, 403);

    const apiKey = Deno.env.get("TAXCLOUD_API_KEY");
    const connectionId = Deno.env.get("TAXCLOUD_CONNECTION_ID");
    let businessOrigin;
    try { businessOrigin = JSON.parse(Deno.env.get("GAC_TAX_ORIGIN_JSON") || "null"); } catch { businessOrigin = null; }
    if (!apiKey || !connectionId || !businessOrigin) {
      return reply({ error: "Tax lookup is not connected yet. Add the three TaxCloud settings described in the Firearm checkout setup guide." }, 503);
    }

    const body = await req.json().catch(() => null);
    let input;
    try { input = normalizeFirearmTaxLookup(body); }
    catch (error) { return reply({ error: error.message }, 400); }
    const origin = normalizeOrigin(businessOrigin);
    const connection = encodeURIComponent(connectionId);
    const endpoint = `https://api.v3.taxcloud.com/tax/connections/${connection}/carts`;
    const response = await fetch(endpoint, {
      method: "POST",
      headers: { "X-API-KEY": apiKey, "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify(taxCloudCartPayload({ ...input, origin, cartId: crypto.randomUUID() })),
      signal: AbortSignal.timeout(15000),
    });
    if (!response.ok) {
      await response.body?.cancel();
      return reply({ error: response.status === 401 || response.status === 403
        ? "TaxCloud rejected its saved credentials. Check the API key and connection ID."
        : "TaxCloud could not calculate this address. Check the address and that the state is active in your TaxCloud nexus settings." }, 502);
    }
    let quote;
    try { quote = normalizeTaxCloudQuote(await response.json()); }
    catch (error) { return reply({ error: error.message }, 502); }
    return reply(quote);
  } catch {
    return reply({ error: "Tax lookup could not be completed. Try again shortly." }, 502);
  }
});

function normalizeOrigin(value: unknown) {
  if (!value || typeof value !== "object") throw new Error("Business tax origin is not configured.");
  const address = value as Record<string, unknown>;
  const clean = (field: unknown, max: number) => typeof field === "string" ? field.trim().slice(0, max) : "";
  const result = {
    line1: clean(address.line1, 128),
    line2: clean(address.line2, 128),
    city: clean(address.city, 64),
    state: clean(address.state, 2).toUpperCase(),
    zip: clean(address.zip, 10),
  };
  if (result.line1.length < 2 || result.city.length < 2 || !/^[A-Z]{2}$/.test(result.state) ||
      !/^\d{5}(?:-\d{4})?$/.test(result.zip)) throw new Error("Business tax origin address is incomplete.");
  return result;
}
