# Prompt: implement the paid Twitter source

Implement the paid Twitter source for Sync Bar (macOS app at
`/Users/prashant/Developer/mac-apps/sync-bar`). The full design is in
`tasks/paid-twitter-spec.md` — read it first and follow it. This prompt is the
execution brief.

## What to build (summary; spec has the detail)

Twitter becomes a **$19.95/mo** paid source via **Lemon Squeezy** (merchant of
record, license keys, no server, no API key). Specifically:

1. **Usage telemetry that can't be turned off.** Add `bypassOptOut: Bool = false`
   to `Telemetry.capture` and emit `x.sync.usage` (handle, x_user_id, stream,
   pages_fetched, items_synced, is_initial_sync, license_instance_id) after a
   successful Twitter crawl in `XSourceClient.listItems`, with
   `bypassOptOut: true`. This is the one event exempt from the analytics opt-out.
2. **`LemonSqueezyClient`** — activate/validate/deactivate against
   `https://api.lemonsqueezy.com/v1/licenses/*` (form-encoded, `Accept: json`),
   stubable URLSession.
3. **`EntitlementManager`** (`ObservableObject`) — owns license key + instance id
   (Keychain), cached status/expiresAt/lastValidatedAt (AppSettings), derives
   `isTwitterEntitled`, runs the **daily 00:00 America/Los_Angeles check** + a
   launch check, with grace via `expiresAt` (never lock out a payer on a transient
   network failure; fail closed only after expiresAt passes). Keep the midnight
   math a pure, unit-tested helper.
4. **Consent + paywall sheet** on adding Twitter (`AddSourceSheet.connectX`,
   before OAuth): paid notice, required checkbox with the EXACT copy in the spec,
   Subscribe button (opens `LEMONSQUEEZY_CHECKOUT_URL`), and a license-key paste
   field that activates. Block reaching OAuth without consent + active entitlement.
5. **Run gate** in `SyncCoordinator.runRule` — skip `.x` rules when not entitled,
   with a clear skip status.
6. **Inactive-sync handling** — lapsed Twitter syncs render inactive (config
   preserved); clicking one opens a reactivate/pay dialog
   (`SyncsHomeView` row `onTap`).
7. **Config + storage** — `LEMONSQUEEZY_CHECKOUT_URL` via Doppler ->
   `Secrets.xcconfig` -> `Info.plist` -> `AuthSecrets`; Keychain keys for the
   license + instance; AppSettings entitlement fields.
8. **Privacy** — update the Settings analytics copy ("Never any personal data" is
   no longer true for paid Twitter usage) and add a subscription/license section
   (status, manage subscription, replace/remove key, privacy-policy link).

## Seam map (exact anchors)

`Telemetry.swift:94` (capture/opt-out) · `XSourceClient.swift:68-112`
(listItems/crawl, emit point ~107) · `SyncCoordinator.swift:214` (runRule gate),
`:134` (timer loop to mirror) · `AddSourceSheet.swift:216` (connectX),
`:68` (.sheet pattern) · `SyncsHomeView.swift:211` (row onTap) · `SyncFlow.swift:36`
(status; consult EntitlementManager from the row view, not the struct) ·
`KeychainStore.swift:27` (Key enum) · `AppSettings.swift` (persisted state) ·
`AuthSecrets.swift` + `Info.plist` + `Secrets.xcconfig.example` +
`scripts/pull-secrets.sh` (checkout URL) · `SettingsView.swift:80` (privacy copy) ·
`Domain.swift:103` (XAccount handle), `Sources.swift:246` (XSourceConfig) ·
`AppDelegate.swift:32` (Telemetry.setup), and create/inject EntitlementManager
alongside Ledger.

## Workflow conventions (this repo)

- Build with `make build`; it bakes `Secrets.xcconfig` (pull via
  `scripts/pull-secrets.sh`, Doppler `sync-bar/dev`). Run the app with
  `open build/Build/Products/Debug/SyncBar.app`; `pkill -x SyncBar` before
  rebuild/test.
- Tests: `make test` (or targeted `xcodebuild test ... -only-testing`).
  TDD-friendly: add `LemonSqueezyClientTests`, `EntitlementManagerTests` (state
  machine + midnight math, with injected clock/timezone), `TelemetryBypassTests`.
  Keep all existing tests green.
- **Trust `xcodebuild`, not SourceKit** — the in-editor "Cannot find type in
  scope" diagnostics are false positives in this project; the real build is truth.
- Work in **small commits, one logical unit each, building green between**
  (telemetry bypass + event; LemonSqueezyClient; EntitlementManager + daily timer;
  config/keychain/settings; paywall sheet + add gate; run gate; inactive row +
  reactivate). Do **not** push; commit locally only.
- No secrets hardcoded. No emoji/emdashes in UI copy; sentence case.

## Before you start — confirm with the user (don't guess)

These are manual, user-owned, and block parts of the flow:

1. **`LEMONSQUEEZY_CHECKOUT_URL`** (and customer-portal URL): is the Lemon Squeezy
   $19.95/mo subscription product with license keys created, and the URL in
   Doppler `sync-bar`? If not, build everything else and stub the URL behind a
   constant, and flag it.
2. **Privacy policy URL** to link in the consent sheet + Settings. If none yet,
   use a placeholder constant and flag it.
3. **Device activation limit** (default 3 if unspecified).

Start by reading `tasks/paid-twitter-spec.md`, then implement in the commit order
above, verifying the Lemon Squeezy validate response shape against the live API
(the `valid` boolean + `license_key.status`) as you wire `LemonSqueezyClient`.
