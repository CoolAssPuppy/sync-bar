// Polar usage-metering relay.
//
// The macOS app cannot ingest metered-billing events directly: Polar's event
// ingestion needs an Organization Access Token, which must never ship in a
// client. This tiny endpoint holds that token server-side. The app POSTs a read
// count plus the user's license key; the relay validates the key (to resolve the
// Polar customer authoritatively, so a client can't bill someone else), then
// ingests one usage event.
//
// Deploy on Vercel (this file is a serverless function at /api/usage) or port the
// handler to any runtime. See README.md.
//
// Required environment variables:
//   POLAR_ORG_ID         - the Polar organization UUID (same as the app's POLAR_ORG_ID)
//   POLAR_ACCESS_TOKEN    - an Organization Access Token (SECRET; server-side only)
// Optional:
//   POLAR_API_BASE        - defaults to https://api.polar.sh
//   POLAR_EVENT_NAME      - the meter event name, defaults to x.sync.usage

const API_BASE = process.env.POLAR_API_BASE || "https://api.polar.sh";
const EVENT_NAME = process.env.POLAR_EVENT_NAME || "x.sync.usage";

export default async function handler(req, res) {
  if (req.method !== "POST") {
    return res.status(405).json({ error: "method_not_allowed" });
  }

  const orgId = process.env.POLAR_ORG_ID;
  const token = process.env.POLAR_ACCESS_TOKEN;
  if (!orgId || !token) {
    return res.status(500).json({ error: "relay_not_configured" });
  }

  const body = typeof req.body === "string" ? safeParse(req.body) : req.body || {};
  const licenseKey = body.license_key;
  const reads = Number(body.reads);
  if (!licenseKey || !Number.isFinite(reads) || reads <= 0) {
    return res.status(400).json({ error: "license_key_and_positive_reads_required" });
  }

  // 1) Validate the key to resolve the customer (authoritative attribution).
  const validate = await fetch(`${API_BASE}/v1/customer-portal/license-keys/validate`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Accept": "application/json" },
    body: JSON.stringify({ key: licenseKey, organization_id: orgId }),
  });
  if (!validate.ok) {
    return res.status(402).json({ error: "license_invalid" });
  }
  const license = await validate.json();
  const customerId = license?.customer?.id;
  if (license?.status !== "granted" || !customerId) {
    return res.status(402).json({ error: "license_not_active" });
  }

  // 2) Ingest one usage event for that customer. Events are immutable in Polar,
  // so the app only reports reads it actually synced (deduped) and only on success.
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
        },
      }],
    }),
  });
  if (!ingest.ok) {
    const detail = await ingest.text();
    return res.status(502).json({ error: "ingest_failed", detail: detail.slice(0, 300) });
  }

  return res.status(200).json({ ok: true, reads });
}

function safeParse(text) {
  try { return JSON.parse(text); } catch { return {}; }
}
