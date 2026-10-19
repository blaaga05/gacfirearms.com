import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const ORIGIN_DEFAULT = "https://gacfirearms.com";
const PREVIEW_ORIGIN = "https://feat-fastbound-firearm-catal.gacfirearms-com.pages.dev";
const TABLE = "gac_firearm_inventory";
const columns = "fastbound_item_id,item_number,serial_number,manufacturer,model,caliber,firearm_type,condition,barrel_length,overall_length,manufacturer_part_number,upc,sku,fastbound_status_id,is_available,price_cents,public_description,published,synced_at";

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

  if (requestOrigin && !allowedOrigins.has(requestOrigin)) {
    return reply({ error: "Origin not allowed" }, 403);
  }
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
    if (!ownerResponse.ok || await ownerResponse.json() !== true) return reply({ error: "Owner access required" }, 403);

    const body = await req.json().catch(() => null);
    if (!body || typeof body.action !== "string") return reply({ error: "Invalid request" }, 400);
    const dbHeaders = { apikey: serviceKey, Authorization: "Bearer " + serviceKey, "Content-Type": "application/json" };
    const db = async (path: string, init: RequestInit = {}) => {
      const r = await fetch(supabaseUrl + "/rest/v1/" + path, {
        ...init,
        headers: { ...dbHeaders, ...(init.headers as Record<string, string> || {}) },
        signal: AbortSignal.timeout(20000),
      });
      if (!r.ok) {
        await r.body?.cancel();
        throw new Error("Database request failed (" + r.status + ")");
      }
      return r.status === 204 ? null : await r.json();
    };

    if (body.action === "sync") {
      const account = Deno.env.get("FASTBOUND_ACCOUNT_NUMBER")?.trim();
      const apiKey = Deno.env.get("FASTBOUND_API_KEY")?.trim();
      if (!account || !apiKey || !/^\d{1,20}$/.test(account)) return reply({ error: "FastBound credentials are not configured correctly" }, 503);
      const auth = "Basic " + btoa(account + ":" + apiKey);
      const fetched: Record<string, unknown>[] = [];
      const pageSize = 100;
      let records = Infinity;
      for (let skip = 0; skip < records; skip += pageSize) {
        if (skip >= 10000) return reply({ error: "Inventory exceeds the safe 10,000 item sync limit" }, 502);
        const url = "https://cloud.fastbound.com/" + encodeURIComponent(account) +
          "/api/Items?take=" + pageSize + "&skip=" + skip;
        const response = await fetch(url, {
          headers: { Authorization: auth, Accept: "application/json" },
          signal: AbortSignal.timeout(20000),
        });
        if (!response.ok) {
          await response.body?.cancel();
          return reply({ error: "FastBound inventory request failed (" + response.status + ")" }, 502);
        }
        const data = await response.json();
        const items = Array.isArray(data.items) ? data.items : [];
        records = Number.isFinite(Number(data.records)) ? Number(data.records) : fetched.length + items.length;
        fetched.push(...items);
        if (items.length < pageSize || fetched.length >= records) break;
      }

      const existing = await db(TABLE + "?select=fastbound_item_id,price_cents,public_description,published");
      const existingById = new Map(existing.map((x: Record<string, unknown>) => [x.fastbound_item_id, x]));
      const syncedAt = new Date().toISOString();
      await db(TABLE + "?is_available=eq.true", {
        method: "PATCH",
        headers: { Prefer: "return=minimal" },
        body: JSON.stringify({ is_available: false, published: false, synced_at: syncedAt }),
      });
      let imported = 0;
      for (let i = 0; i < fetched.length; i += 100) {
        const rows = fetched.slice(i, i + 100).filter((x) => typeof x.id === "string" && typeof x.serial === "string").map((x) => {
          const status = x.status && typeof x.status === "object" ? x.status as Record<string, unknown> : {};
          const available = Number(status.id) === 1 && !x.disposed && !x.deleted && !x.isTheftLoss && !x.isDestroyed && !x.doNotDispose;
          return {
            fastbound_item_id: x.id,
            item_number: typeof x.itemNumber === "string" ? x.itemNumber : "",
            serial_number: x.serial,
            manufacturer: typeof x.manufacturer === "string" ? x.manufacturer : "",
            model: typeof x.model === "string" ? x.model : "",
            caliber: typeof x.caliber === "string" ? x.caliber : "",
            firearm_type: typeof x.type === "string" ? x.type : "",
            condition: typeof x.condition === "string" ? x.condition : "",
            barrel_length: typeof x.barrelLength === "number" ? x.barrelLength : null,
            overall_length: typeof x.overallLength === "number" ? x.overallLength : null,
            manufacturer_part_number: typeof x.mpn === "string" ? x.mpn : "",
            upc: typeof x.upc === "string" ? x.upc : "",
            sku: typeof x.sku === "string" ? x.sku : "",
            fastbound_status_id: Number.isFinite(Number(status.id)) ? Number(status.id) : null,
            is_available: available,
            price_cents: available ? existingById.get(x.id)?.price_cents ?? null : existingById.get(x.id)?.price_cents ?? null,
            public_description: existingById.get(x.id)?.public_description || "",
            published: available ? Boolean(existingById.get(x.id)?.published) : false,
            synced_at: syncedAt,
          };
        });
        if (!rows.length) continue;
        await db(TABLE + "?on_conflict=fastbound_item_id", {
          method: "POST",
          headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
          body: JSON.stringify(rows),
        });
        imported += rows.length;
      }
      return reply({ success: true, imported, syncedAt });
    }

    if (body.action === "list") {
      const items = await db(TABLE + "?select=" + encodeURIComponent(columns) + "&order=manufacturer.asc,model.asc");
      return reply({ items });
    }
    if (body.action === "orders") {
      const orders = await db("gac_firearm_order_requests?select=id,firearm_item_id,firearm_name,price_cents,buyer_name,buyer_email,buyer_phone,residence_state,transfer_method,destination_ffl_name,destination_ffl_city,destination_ffl_state,destination_ffl_phone,destination_ffl_email,review_status,created_at&order=created_at.desc&limit=100");
      return reply({ orders });
    }
    if (body.action === "update") {
      if (typeof body.itemId !== "string" || !/^[0-9a-f-]{36}$/i.test(body.itemId)) return reply({ error: "Invalid item" }, 400);
      const patch: Record<string, unknown> = {};
      if (typeof body.description === "string") {
        if (body.description.length > 3000) return reply({ error: "Description is too long" }, 400);
        patch.public_description = body.description.trim();
      }
      if (body.priceCents !== undefined) {
        if (body.priceCents !== null && (!Number.isInteger(body.priceCents) || body.priceCents < 1 || body.priceCents > 100000000)) return reply({ error: "Enter a valid price" }, 400);
        patch.price_cents = body.priceCents;
      }
      if (typeof body.published === "boolean") patch.published = body.published;
      if (patch.published === true && (patch.price_cents === null || patch.price_cents === undefined)) {
        const current = await db(TABLE + "?select=price_cents&fastbound_item_id=eq." + encodeURIComponent(body.itemId));
        if (!current[0]?.price_cents) return reply({ error: "Set a price before publishing" }, 400);
      }
      if (!Object.keys(patch).length) return reply({ error: "Nothing to update" }, 400);
      patch.updated_at = new Date().toISOString();
      await db(TABLE + "?fastbound_item_id=eq." + encodeURIComponent(body.itemId), {
        method: "PATCH",
        headers: { Prefer: "return=minimal" },
        body: JSON.stringify(patch),
      });
      return reply({ success: true });
    }
    if (body.action === "review-request") {
      if (typeof body.requestId !== "string" || !/^[0-9a-f-]{36}$/i.test(body.requestId) || !["contacted", "declined"].includes(body.status)) return reply({ error: "Invalid request status" }, 400);
      await db("gac_firearm_order_requests?id=eq." + encodeURIComponent(body.requestId), {
        method: "PATCH",
        headers: { Prefer: "return=minimal" },
        body: JSON.stringify({ review_status: body.status }),
      });
      return reply({ success: true });
    }
    return reply({ error: "Unknown action" }, 400);
  } catch {
    return reply({ error: "The FastBound inventory request could not finish. Try again shortly." }, 502);
  }
});
