import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { normalizeFirearmPricing } from "../_shared/firearm-pricing.mjs";

const ORIGIN_DEFAULT = "https://gacfirearms.com";
const PREVIEW_ORIGIN = "https://feat-firearm-pricing-config.gacfirearms-com.pages.dev";
const TABLE = "gac_firearm_checkout_pricing";

Deno.serve(async (req: Request) => {
  const configuredOrigin = Deno.env.get("GAC_SITE_ORIGIN") || ORIGIN_DEFAULT;
  const requestOrigin = req.headers.get("origin") || "";
  const allowedOrigins = new Set([ORIGIN_DEFAULT, configuredOrigin, PREVIEW_ORIGIN]);
  const origin = allowedOrigins.has(requestOrigin) ? requestOrigin : configuredOrigin;
  const headers = {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
  const reply = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers });

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
  const authHeaders = { apikey: publishableKey, Authorization: authorization };
  try {
    const user = await fetch(supabaseUrl + "/auth/v1/user", { headers: authHeaders, signal: AbortSignal.timeout(10000) });
    if (!user.ok) return reply({ error: "Sign in again" }, 401);
    const owner = await fetch(supabaseUrl + "/rest/v1/rpc/gac_is_owner", {
      method: "POST", headers: { ...authHeaders, "Content-Type": "application/json" }, body: "{}",
      signal: AbortSignal.timeout(10000),
    });
    if (!owner.ok || await owner.json() !== true) return reply({ error: "Owner access required" }, 403);

    const body = await req.json().catch(() => null);
    if (!body || !["get", "save"].includes(body.action)) return reply({ error: "Invalid request" }, 400);
    const dbHeaders = { apikey: serviceKey, Authorization: "Bearer " + serviceKey, "Content-Type": "application/json" };
    const base = supabaseUrl + "/rest/v1/" + TABLE;
    if (body.action === "get") {
      const result = await fetch(base + "?select=shipping_cents,tax_rates,updated_at&singleton=eq.true", {
        headers: dbHeaders, signal: AbortSignal.timeout(10000),
      });
      if (!result.ok) return reply({ error: "Pricing settings could not be loaded" }, 502);
      const rows = await result.json();
      return reply(rows[0] || { shipping_cents: 0, tax_rates: [], updated_at: null });
    }

    let pricing;
    try { pricing = normalizeFirearmPricing(body); }
    catch (error) { return reply({ error: error.message }, 400); }
    const { shippingCents, taxRates } = pricing;

    const saved = await fetch(base + "?on_conflict=singleton", {
      method: "POST", headers: { ...dbHeaders, Prefer: "resolution=merge-duplicates,return=representation" },
      body: JSON.stringify({ singleton: true, shipping_cents: shippingCents, tax_rates: taxRates, updated_by: (await user.json()).id, updated_at: new Date().toISOString() }),
      signal: AbortSignal.timeout(10000),
    });
    if (!saved.ok) return reply({ error: "Pricing settings could not be saved." }, 502);
    const rows = await saved.json();
    return reply(rows[0] || { shipping_cents: shippingCents, tax_rates: taxRates });
  } catch {
    return reply({ error: "Pricing settings could not be reached. Try again shortly." }, 502);
  }
});
