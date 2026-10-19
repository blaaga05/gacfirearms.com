import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const ORIGIN_DEFAULT = "https://gacfirearms.com";
const PREVIEW_ORIGIN = "https://feat-fastbound-firearm-catal.gacfirearms-com.pages.dev";
Deno.serve(async (req: Request) => {
  const requestOrigin = req.headers.get("origin") || "";
  const configuredOrigin = Deno.env.get("GAC_SITE_ORIGIN") || ORIGIN_DEFAULT;
  const allowedOrigins = new Set([ORIGIN_DEFAULT, configuredOrigin, PREVIEW_ORIGIN]);
  const origin = requestOrigin || configuredOrigin;
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

  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) return reply({ error: "Order requests are temporarily unavailable" }, 503);
  const body = await req.json().catch(() => null);
  if (!body || typeof body !== "object") return reply({ error: "Enter the requested information" }, 400);

  const clean = (value: unknown, max: number) => typeof value === "string" ? value.trim().slice(0, max) : "";
  const firearmId = clean(body.firearmId, 40);
  const name = clean(body.name, 120);
  const email = clean(body.email, 254).toLowerCase();
  const phone = clean(body.phone, 40);
  const state = clean(body.state, 2).toUpperCase();
  const method = body.transferMethod === "destination_ffl" ? "destination_ffl" :
    body.transferMethod === "local_pickup" ? "local_pickup" : "";
  const fflName = clean(body.fflName, 160);
  const fflCity = clean(body.fflCity, 100);
  const fflState = clean(body.fflState, 2).toUpperCase();
  const fflPhone = clean(body.fflPhone, 40);
  const fflEmail = clean(body.fflEmail, 254).toLowerCase();
  if (!/^[0-9a-f-]{36}$/i.test(firearmId) || name.length < 2 ||
      !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || !/^[A-Z]{2}$/.test(state) ||
      !method || body.eligible !== true || body.understandsReview !== true) {
    return reply({ error: "Check the required details and acknowledgments" }, 400);
  }
  if (method === "destination_ffl" && (fflName.length < 2 || fflCity.length < 2 ||
      !/^[A-Z]{2}$/.test(fflState) || (!fflPhone && !fflEmail) ||
      (fflEmail && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(fflEmail)))) {
    return reply({ error: "Enter the destination FFL name, city, state, and phone or email" }, 400);
  }
  const auth = { apikey: key, Authorization: "Bearer " + key, "Content-Type": "application/json" };
  try {
    const catalogUrl = url + "/rest/v1/gac_firearm_catalog?select=id,manufacturer,model,caliber,price_cents&id=eq." + encodeURIComponent(firearmId);
    const itemResponse = await fetch(catalogUrl, { headers: auth, signal: AbortSignal.timeout(10000) });
    if (!itemResponse.ok) return reply({ error: "This firearm is no longer available for an order request" }, 409);
    const items = await itemResponse.json();
    const item = items[0];
    if (!item) return reply({ error: "This firearm is no longer available for an order request" }, 409);

    const since = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const countUrl = url + "/rest/v1/gac_firearm_order_requests?select=id&buyer_email=eq." +
      encodeURIComponent(email) + "&created_at=gte." + encodeURIComponent(since);
    const countResponse = await fetch(countUrl, { headers: { ...auth, Prefer: "count=exact", Range: "0-5" }, signal: AbortSignal.timeout(10000) });
    if (countResponse.ok) {
      const range = countResponse.headers.get("content-range") || "";
      const count = Number(range.split("/").pop());
      if (Number.isFinite(count) && count >= 5) return reply({ error: "Too many requests from this email. Please contact GAC directly." }, 429);
    }

    const firearmName = [item.manufacturer, item.model, item.caliber].filter(Boolean).join(" ");
    const payload = {
      firearm_item_id: item.id,
      firearm_name: firearmName,
      price_cents: item.price_cents,
      buyer_name: name,
      buyer_email: email,
      buyer_phone: phone,
      residence_state: state,
      transfer_method: method,
      destination_ffl_name: method === "destination_ffl" ? fflName : "",
      destination_ffl_city: method === "destination_ffl" ? fflCity : "",
      destination_ffl_state: method === "destination_ffl" ? fflState : null,
      destination_ffl_phone: method === "destination_ffl" ? fflPhone : "",
      destination_ffl_email: method === "destination_ffl" ? fflEmail : "",
      buyer_affirms_eligibility: true,
      buyer_acknowledges_review: true,
    };
    const saved = await fetch(url + "/rest/v1/gac_firearm_order_requests", {
      method: "POST",
      headers: { ...auth, Prefer: "return=representation" },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(10000),
    });
    if (!saved.ok) {
      await saved.body?.cancel();
      return reply({ error: "The request could not be saved. Contact GAC and try again." }, 502);
    }
    return reply({ submitted: true, requestId: (await saved.json())?.[0]?.id }, 201);
  } catch {
    return reply({ error: "The request could not finish. Please try again shortly." }, 502);
  }
});
