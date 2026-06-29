# Polar usage relay

A tiny serverless endpoint that lets Sync Bar meter paid-class usage (tweets read)
through Polar without shipping a secret in the app.

## Why it exists

Polar's license-key **validate** endpoint needs no auth, so the app gates
entitlement on its own. But Polar's **event ingestion** (what metered billing
runs on) requires an Organization Access Token that must never be in a client.
This relay holds that token. The app POSTs a read count plus the user's license
key; the relay validates the key (resolving the customer authoritatively, so a
client can't bill someone else) and ingests one usage event.

If you only want the flat $4.99/month base and no per-read metering, you don't
need this relay at all. Leave `POLAR_USAGE_RELAY_URL` unset and the app's usage
reporter no-ops; entitlement still works.

## Deploy (Vercel)

1. From this folder: `npx vercel` (or push to a Git repo linked to Vercel). The
   function is served at `/api/usage`.
2. Set environment variables in the Vercel project:
   - `POLAR_ORG_ID` — your Polar organization UUID (same value as the app's).
   - `POLAR_ACCESS_TOKEN` — an Organization Access Token (Polar → Settings →
     Developers). Secret.
   - `RELAY_SHARED_SECRET` — recommended. A secret the app sends in `x-relay-token`.
     When set, the relay rejects requests without it. Put the same value in Doppler
     `sync-bar` as `POLAR_RELAY_TOKEN` so the app sends it. Always set this in
     production.
   - optional `MAX_READS` (defaults to `25000`, the app's per-crawl ceiling). A
     single report above this is rejected.
   - optional `POLAR_API_BASE` (defaults to `https://api.polar.sh`; use the
     sandbox base while testing).
   - optional `POLAR_EVENT_NAME` (defaults to `x.sync.usage`; must match the Meter
     you create in Polar).
3. Copy the deployed URL, e.g. `https://your-relay.vercel.app/api/usage`, into
   Doppler `sync-bar` as `POLAR_USAGE_RELAY_URL`, then rebuild the app.

## Polar setup it depends on

- A **Meter** named to match `POLAR_EVENT_NAME`, aggregating the `reads` field.
- A **metered price** on the subscription product (e.g. per read, or per 1,000),
  so ingested events bill the customer.

## Request shape

```
POST /api/usage
{ "license_key": "...", "reads": 42, "stream": "bookmarks",
  "x_user_id": "123", "is_initial": "false" }
```

Returns `200 { ok: true, reads }` on success, `400` for a malformed/out-of-range
request, `401` for a missing/wrong shared secret, `402` for an invalid/inactive
license, `502` if Polar is unreachable. The app treats every response as
best-effort and never blocks a sync on it.

## Security posture

This is a billing sink, so the handler enforces defense in depth:

- **Bounded input.** `reads` must be a positive integer no larger than `MAX_READS`,
  so a single request can't inflate a bill with an absurd value.
- **Shared-secret gate.** With `RELAY_SHARED_SECRET` set, anonymous callers are
  rejected, keeping random traffic off the sink and off your Polar quota. This is a
  speed bump, not authentication: the app ships the secret in its bundle, so anyone
  who extracts it can still call the relay. The bounded `reads` and server-side
  license validation are what actually limit the damage.
- **Authoritative attribution.** The customer is resolved by validating the license
  key server-side, not trusted from the client, so a caller can't bill someone else.
- **No error leakage.** Polar's error text is logged, never echoed to the caller.

Two controls you must add at deploy time:

- **Rate limiting.** Put a per-IP / per-route limit at the edge (Vercel Firewall or
  equivalent). The function itself is stateless and can't rate-limit reliably.
- **Replay dedup (optional but recommended).** The app sends a fresh
  `idempotency_key` per report; back the relay with a KV store (e.g. Vercel KV) and
  drop a key you've already seen, so a captured request can't be replayed to
  accumulate charges. Polar events are immutable, so dedup must happen before ingest.

## A note on double counting

Polar events are immutable (no edits, no deletes). The app reports only reads it
actually synced (deduped by its processed-id set) and only after a successful
crawl, so retries don't re-report. If you later proxy X calls for authoritative
counts, move the metering into that proxy.
