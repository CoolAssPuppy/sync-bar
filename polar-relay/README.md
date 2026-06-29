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

Returns `200 { ok: true, reads }` on success, `402` for an invalid/inactive
license, `502` if Polar ingestion fails. The app treats every response as
best-effort and never blocks a sync on it.

## A note on double counting

Polar events are immutable (no edits, no deletes). The app reports only reads it
actually synced (deduped by its processed-id set) and only after a successful
crawl, so retries don't re-report. If you later proxy X calls for authoritative
counts, move the metering into that proxy.
