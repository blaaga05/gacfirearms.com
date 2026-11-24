import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SITE_ORIGIN = "https://gacfirearms.com";
const ONESIGNAL_APP_ID = "ea15f827-d569-4965-91b9-dec69c6de251";

Deno.serve(async (req: Request) => {
  const headers = { "Content-Type": "application/json", "Cache-Control": "no-store" };
  const reply = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers });
  if (req.method !== "POST") return reply({ error: "POST required" }, 405);

  const token = req.headers.get("x-gac-collection-full-token") || "";
  if (!/^[a-f0-9]{64}$/.test(token)) return reply({ error: "Authentication required" }, 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const oneSignalKey = Deno.env.get("ONESIGNAL_REST_API_KEY");
  if (!supabaseUrl || !serviceKey || !oneSignalKey) {
    return reply({ error: "Collection alert service is not configured" }, 503);
  }

  const rpc = async (name: string, body: Record<string, unknown>) => {
    const response = await fetch(supabaseUrl + "/rest/v1/rpc/" + name, {
      method: "POST",
      headers: {
        apikey: serviceKey,
        Authorization: "Bearer " + serviceKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(15000),
    });
    const text = await response.text();
    let data: unknown = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = null; }
    if (!response.ok) throw new Error(name + " failed with HTTP " + response.status);
    return data;
  };

  try {
    if (await rpc("gac_verify_collection_full_push_token", { p_token: token }) !== true) {
      return reply({ error: "Authentication failed" }, 401);
    }

    const claimed = await rpc("gac_claim_collection_full_push_alerts", { p_limit: 20 });
    const alerts = Array.isArray(claimed) ? claimed as Array<Record<string, unknown>> : [];
    let sent = 0;
    let failed = 0;

    for (const alert of alerts) {
      const queueId = typeof alert.queue_id === "string" ? alert.queue_id : "";
      try {
        const ownerIds = Array.isArray(alert.owner_ids)
          ? alert.owner_ids.filter((id): id is string => typeof id === "string" && /^[0-9a-f-]{36}$/i.test(id))
          : [];
        if (!queueId || ownerIds.length === 0) throw new Error("No owner account is available for the alert");

        const callsign = typeof alert.callsign === "string" ? alert.callsign : "A GAC collection";
        const assigned = Number(alert.assigned) || 0;
        const quantity = Number(alert.quantity) || 0;
        const notification = await fetch("https://api.onesignal.com/notifications", {
          method: "POST",
          headers: {
            Authorization: "Key " + oneSignalKey,
            "Content-Type": "application/json",
            Accept: "application/json",
          },
          body: JSON.stringify({
            app_id: ONESIGNAL_APP_ID,
            include_aliases: { external_id: ownerIds },
            target_channel: "push",
            headings: { en: "Collection full — check payments" },
            contents: { en: callsign + " is full (" + assigned + "/" + quantity + "). Review payments before the wheel." },
            url: SITE_ORIGIN + "/account.html",
          }),
          signal: AbortSignal.timeout(20000),
        });
        if (!notification.ok) {
          await notification.body?.cancel();
          throw new Error("OneSignal returned HTTP " + notification.status);
        }
        await rpc("gac_finish_collection_full_push_alert", {
          p_queue_id: queueId,
          p_success: true,
          p_error: null,
        });
        sent++;
      } catch (error) {
        if (queueId) {
          try {
            await rpc("gac_finish_collection_full_push_alert", {
              p_queue_id: queueId,
              p_success: false,
              p_error: error instanceof Error ? error.message : "Push delivery failed",
            });
          } catch { /* Leave the lease to expire so the scheduled job can retry. */ }
        }
        failed++;
      }
    }
    const claimedRecognitions = await rpc("gac_claim_recognition_member_pushes", { p_limit: 20 });
    const recognitions = Array.isArray(claimedRecognitions)
      ? claimedRecognitions as Array<Record<string, unknown>>
      : [];
    let recognitionSent = 0;
    let recognitionFailed = 0;

    for (const recognition of recognitions) {
      const queueId = typeof recognition.queue_id === "string" ? recognition.queue_id : "";
      try {
        const memberId = typeof recognition.member_id === "string" ? recognition.member_id : "";
        if (!queueId || !/^[0-9a-f-]{36}$/i.test(memberId)) {
          throw new Error("A valid recognized member account is required");
        }
        const memberCallsign = typeof recognition.member_callsign === "string" ? recognition.member_callsign : "Member";
        const groupCallsign = typeof recognition.group_callsign === "string" ? recognition.group_callsign : "GAC collection";
        const editionNumber = Number(recognition.edition_number);
        if (!Number.isInteger(editionNumber)) {
          throw new Error("Recognition details are incomplete");
        }

        const notification = await fetch("https://api.onesignal.com/notifications", {
          method: "POST",
          headers: {
            Authorization: "Key " + oneSignalKey,
            "Content-Type": "application/json",
            Accept: "application/json",
          },
          body: JSON.stringify({
            app_id: ONESIGNAL_APP_ID,
            include_aliases: { external_id: [memberId] },
            target_channel: "push",
            headings: { en: "You were recognized!" },
            contents: { en: "Your number #" + editionNumber + " in " + groupCallsign + " has been selected! Check your messages at GAC." },
            url: SITE_ORIGIN + "/account.html",
          }),
          signal: AbortSignal.timeout(20000),
        });
        if (!notification.ok) {
          await notification.body?.cancel();
          throw new Error("OneSignal returned HTTP " + notification.status);
        }
        await rpc("gac_finish_recognition_member_push", {
          p_queue_id: queueId,
          p_success: true,
          p_error: null,
        });
        recognitionSent++;
      } catch (error) {
        if (queueId) {
          try {
            await rpc("gac_finish_recognition_member_push", {
              p_queue_id: queueId,
              p_success: false,
              p_error: error instanceof Error ? error.message : "Recognition push delivery failed",
            });
          } catch { /* Leave the lease to expire so the scheduled job can retry. */ }
        }
        recognitionFailed++;
      }
    }
    let claimedOwnerMessages: unknown = [];
    try {
      claimedOwnerMessages = await rpc("gac_claim_owner_message_pushes", { p_limit: 20 });
    } catch (error) {
      console.error("Owner message push queue is not available:", error instanceof Error ? error.message : String(error));
    }
    const ownerMessages = Array.isArray(claimedOwnerMessages)
      ? claimedOwnerMessages as Array<Record<string, unknown>>
      : [];
    let ownerMessageSent = 0;
    let ownerMessageFailed = 0;

    for (const ownerMessage of ownerMessages) {
      const queueId = typeof ownerMessage.queue_id === "string" ? ownerMessage.queue_id : "";
      try {
        const ownerIds = Array.isArray(ownerMessage.owner_ids)
          ? ownerMessage.owner_ids.filter((id): id is string => typeof id === "string" && /^[0-9a-f-]{36}$/i.test(id))
          : [];
        if (!queueId || ownerIds.length === 0) throw new Error("No owner account is available for this message alert");

        const memberCallsign = typeof ownerMessage.member_callsign === "string" ? ownerMessage.member_callsign.trim().slice(0, 64) || "A GAC member" : "A GAC member";
        const notification = await fetch("https://api.onesignal.com/notifications", {
          method: "POST",
          headers: {
            Authorization: "Key " + oneSignalKey,
            "Content-Type": "application/json",
            Accept: "application/json",
          },
          body: JSON.stringify({
            app_id: ONESIGNAL_APP_ID,
            include_aliases: { external_id: ownerIds },
            target_channel: "push",
            headings: { en: "New GAC member message" },
            contents: { en: memberCallsign + " sent you a private message. Open GAC Messages to reply." },
            url: SITE_ORIGIN + "/account.html?openMessages=1",
          }),
          signal: AbortSignal.timeout(20000),
        });
        if (!notification.ok) {
          await notification.body?.cancel();
          throw new Error("OneSignal returned HTTP " + notification.status);
        }
        await rpc("gac_finish_owner_message_push", {
          p_queue_id: queueId,
          p_success: true,
          p_error: null,
        });
        ownerMessageSent++;
      } catch (error) {
        if (queueId) {
          try {
            await rpc("gac_finish_owner_message_push", {
              p_queue_id: queueId,
              p_success: false,
              p_error: error instanceof Error ? error.message : "Owner message push failed",
            });
          } catch { /* Leave the lease to expire so the scheduled job can retry. */ }
        }
        ownerMessageFailed++;
      }
    }
    return reply({
      success: true,
      processed: alerts.length,
      sent,
      failed,
      recognitionProcessed: recognitions.length,
      recognitionSent,
      recognitionFailed,
      ownerMessageProcessed: ownerMessages.length,
      ownerMessageSent,
      ownerMessageFailed,
    });
  } catch (error) {
    console.error("gac-collection-full-alert failed:", error instanceof Error ? error.message : String(error));
    return reply({ error: "Collection alert processing failed" }, 502);
  }
});
