import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SITE_ORIGIN = "https://gacfirearms.com";
const ONESIGNAL_APP_ID = "ea15f827-d569-4965-91b9-dec69c6de251";

Deno.serve(async (req: Request) => {
  const requestOrigin = req.headers.get("origin") || "";
  const headers = {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    "Access-Control-Allow-Origin": SITE_ORIGIN,
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
  const reply = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers });

  if (requestOrigin && requestOrigin !== SITE_ORIGIN) return reply({ error: "Origin not allowed" }, 403);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (req.method !== "POST") return reply({ error: "POST required" }, 405);

  const authorization = req.headers.get("authorization") || "";
  if (!/^Bearer \S+$/.test(authorization)) return reply({ error: "Sign in required" }, 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const publishableKey = Deno.env.get("SUPABASE_ANON_KEY") ||
    (() => { try { return JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS") || "{}").default; } catch { return ""; } })();
  const oneSignalKey = Deno.env.get("ONESIGNAL_REST_API_KEY");
  if (!supabaseUrl || !publishableKey || !oneSignalKey) {
    return reply({ error: "Push sending is not configured yet" }, 503);
  }

  const authHeaders = { apikey: publishableKey, Authorization: authorization };
  try {
    const user = await fetch(supabaseUrl + "/auth/v1/user", {
      headers: authHeaders,
      signal: AbortSignal.timeout(10000),
    });
    if (!user.ok) return reply({ error: "Sign in again" }, 401);
    const ownerResponse = await fetch(supabaseUrl + "/rest/v1/rpc/gac_is_owner", {
      method: "POST",
      headers: { ...authHeaders, "Content-Type": "application/json" },
      body: "{}",
      signal: AbortSignal.timeout(10000),
    });
    if (!ownerResponse.ok || await ownerResponse.json() !== true) {
      return reply({ error: "Owner access required" }, 403);
    }

    const body = await req.json().catch(() => null);
    const title = typeof body?.title === "string" ? body.title.trim() : "";
    const message = typeof body?.message === "string" ? body.message.trim() : "";
    const url = typeof body?.url === "string" ? body.url.trim() : "";
    const subscriptionId = typeof body?.subscriptionId === "string" ? body.subscriptionId.trim() : "";
    if (!title || title.length > 80 || !message || message.length > 240) {
      return reply({ error: "Enter a title (up to 80 characters) and message (up to 240 characters)." }, 400);
    }
    if (!/^[0-9a-f-]{36}$/i.test(subscriptionId)) {
      return reply({ error: "A valid subscribed browser/device is required for this test send." }, 400);
    }
    if (url) {
      try {
        if (new URL(url).origin !== SITE_ORIGIN) return reply({ error: "Push links must point to gacfirearms.com." }, 400);
      } catch {
        return reply({ error: "Enter a valid GAC website link." }, 400);
      }
    }

    const notification: Record<string, unknown> = {
      app_id: ONESIGNAL_APP_ID,
      include_subscription_ids: [subscriptionId],
      headings: { en: title },
      contents: { en: message },
    };
    if (url) notification.url = url;

    const response = await fetch("https://api.onesignal.com/notifications", {
      method: "POST",
      headers: {
        Authorization: "Key " + oneSignalKey,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(notification),
      signal: AbortSignal.timeout(20000),
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) return reply({ error: "OneSignal could not send the notification. Check the OneSignal app and server key." }, 502);
    return reply({ success: true, id: result.id || null, recipients: result.recipients ?? null });
  } catch {
    return reply({ error: "The push notification could not be sent. Try again shortly." }, 502);
  }
});
