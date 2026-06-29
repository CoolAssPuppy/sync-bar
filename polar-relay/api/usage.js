// Polar usage-metering relay.
//
// The macOS app cannot ingest metered-billing events directly: Polar's event
// ingestion needs an Organization Access Token, which must never ship in a
// client. This tiny endpoint holds that token server-side. The app POSTs a read
// count plus the user's license key; the relay validates the key (to resolve the
// Polar customer authoritatively, so a client can't bill someone else), then
// ingests one usage event.
//
// This is a billing sink, so it is hardened accordingly:
//   * `reads` is bounded — an attacker can't inflate a bill with a huge value.
//   * an optional shared secret (`RELAY_SHARED_SECRET`) gates the endpoint so it
//     isn't open to anonymous drive-by abuse / Polar-quota burn. NOTE: the app
//     ships this secret in its bundle, so it stops anonymous callers, not anyone
//     who extracts it. Treat it as a speed bump, not authentication.
//   * Polar's raw error text is logged, never echoed to the caller.
//   * `reads` is bounded by MAX_READS (default near the app's real per-report max).
// NOT implemented here: replay dedup. Polar events are append-only and this handler
// does not dedup on `idempotency_key`, so a replayed POST double-counts. Add a
// KV-backed check (see README) before relying on metered billing. Rate limiting
// belongs at the platform edge (e.g. Vercel Firewall).
//
// Deploy on Vercel (this file is a serverless function at /api/usage) or port the
// handler to any runtime.
//
// Required environment variables:
//   POLAR_ORG_ID         - the Polar organization UUID (same as the app's POLAR_ORG_ID)
//   POLAR_ACCESS_TOKEN    - an Organization Access Token (SECRET; server-side only)
// Recommended:
//   RELAY_SHARED_SECRET   - a secret the app sends in `x-relay-token`; when set, the
//                           relay rejects requests without it. Always set in production.
// Optional:
//   POLAR_API_BASE        - defaults to https://api.polar.sh
//   POLAR_EVENT_NAME      - the meter event name, defaults to x.sync.usage
//   MAX_READS             - upper bound on a single report, defaults to 1000. A
//                           legitimate report is one crawl, itself bounded by the
//                           app's ~650/month read cap, so 1000 leaves headroom
//                           without letting one call post an absurd number. Raise
//                           it only if you raise the app's monthly cap.

import crypto from "node:crypto";

const API_BASE = process.env.POLAR_API_BASE || "https://api.polar.sh";
const EVENT_NAME = process.env.POLAR_EVENT_NAME || "x.sync.usage";
const MAX_READS = Number(process.env.MAX_READS || 1000);

export default async function handler(req, res) {
  if (req.method !== "POST") {
    return res.status(405).json({ error: "method_not_allowed" });
  }

  const orgId = process.env.POLAR_ORG_ID;
  const token = process.env.POLAR_ACCESS_TOKEN;
  if (!orgId || !token) {
    return res.status(500).json({ error: "relay_not_configured" });
  }

  // Shared-secret gate. When RELAY_SHARED_SECRET is set, only callers that send
  // the matching `x-relay-token` get through, keeping anonymous callers off the
  // billing sink. Compared in constant time to avoid a timing oracle.
  const expectedSecret = process.env.RELAY_SHARED_SECRET;
  if (expectedSecret) {
    const provided = req.headers["x-relay-token"];
    if (typeof provided !== "string" || !timingSafeEqual(provided, expectedSecret)) {
      return res.status(401).json({ error: "unauthorized" });
    }
  }

  const body = typeof req.body === "string" ? safeParse(req.body) : req.body || {};
  const licenseKey = body.license_key;
  const reads = Number(body.reads);

  if (typeof licenseKey !== "string" || licenseKey.length === 0 || licenseKey.length > 200) {
    return res.status(400).json({ error: "invalid_license_key" });
  }
  // Bound the attacker-controlled value: a positive integer no larger than a
  // single legitimate crawl can produce. This is the core anti-billing-fraud check.
  if (!Number.isInteger(reads) || reads <= 0 || reads > MAX_READS) {
    return res.status(400).json({ error: "invalid_reads", max: MAX_READS });
  }

  // 1) Validate the key to resolve the customer (authoritative attribution).
  let license;
  try {
    const validate = await fetch(`${API_BASE}/v1/customer-portal/license-keys/validate`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Accept": "application/json" },
      body: JSON.stringify({ key: licenseKey, organization_id: orgId }),
    });
    if (!validate.ok) {
      return res.status(402).json({ error: "license_invalid" });
    }
    license = await validate.json();
  } catch (err) {
    console.error("polar validate failed:", err);
    return res.status(502).json({ error: "upstream_unavailable" });
  }

  const customerId = license?.customer?.id;
  if (license?.status !== "granted" || !customerId) {
    return res.status(402).json({ error: "license_not_active" });
  }

  // 2) Ingest one usage event for that customer. Events are immutable in Polar,
  // so the app only reports reads it actually synced (deduped) and only on success.
  // `idempotency_key` is forwarded so a KV-backed deployment can drop replays.
  try {
    const ingest = await fetch(`${API_BASE}/v1/events/ingest`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "Authorization": `Bearer ${token}`,
      },
      body: JSON.stringify({
        events: [{
          name: EVENT_NAME,
          customer_id: customerId,
          metadata: {
            reads,
            stream: String(body.stream || ""),
            x_user_id: String(body.x_user_id || ""),
            is_initial: String(body.is_initial || "false"),
            idempotency_key: String(body.idempotency_key || ""),
          },
        }],
      }),
    });
    if (!ingest.ok) {
      // Log Polar's detail server-side; never echo it to the caller.
      console.error("polar ingest failed:", ingest.status, await ingest.text());
      return res.status(502).json({ error: "ingest_failed" });
    }
  } catch (err) {
    console.error("polar ingest threw:", err);
    return res.status(502).json({ error: "upstream_unavailable" });
  }

  return res.status(200).json({ ok: true, reads });
}

function timingSafeEqual(a, b) {
  const ab = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  if (ab.length !== bb.length) return false;
  return crypto.timingSafeEqual(ab, bb);
}

function safeParse(text) {
  try { return JSON.parse(text); } catch { return {}; }
}
