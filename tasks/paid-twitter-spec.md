# Spec: paid Twitter source (entitlement, consent, usage metering)

## Decisions that supersede this spec (2026-06-29)

The body below still describes the design, but two choices changed after it was written:

- **Provider is Polar.sh, not Lemon Squeezy.** The entitlement layer is built behind a
  `LicenseProvider` protocol; `PolarLicenseClient` is the conformer. Polar's
  customer-portal license-key `validate`/`activate`/`deactivate` endpoints need no auth
  (body carries `key` + `organization_id`), so the entitlement gate stays serverless.
- **Pricing is $6.99/month flat (Option A)**, not $19.95 and not metered. A Polar
  subscription with a License Keys benefit is the entitlement gate. There is no
  per-tweet charge; instead a client-side monthly read cap (`ReadBudget`, 650 reads)
  bounds the maker's X cost (~$3.25/subscriber at $0.005/read, under the price). The
  metered relay (`polar-relay/`, `UsageReporter`, `POLAR_USAGE_RELAY_URL`) is built but
  DORMANT — deploy it later to switch on per-read billing. Activation limit: 2 devices.
- **Optionality:** Twitter is the first instance of a general "paid Sync class". Gating
  routes through a `PaidFeature` abstraction (sync -> feature -> entitlement), so a
  future paywall over another sync or a group is a data change, not a code sweep.

Read `tasks/todo.md` for the commit-by-commit plan.

## Goal

Make Twitter a paid source at **$19.95 USD/month** via Lemon Squeezy (merchant of
record). Only paying users can add or run Twitter syncs. When a subscription
lapses, the user's Twitter syncs go inactive (config preserved, not deleted) and
clicking one prompts payment. Every Twitter sync emits a usage event the user
cannot turn off, so the maker can see who is consuming the X API budget. Adding a
Twitter source requires explicit consent to share the user's handle and sync
counts.

This is the app's first collection of personal data. Everything else stays as it
is; non-Twitter sources are unaffected.

## Provider: Lemon Squeezy (Option A, merchant of record)

- Flat **$19.95/mo subscription** product with **license keys enabled**.
- The License API needs **no server and no API key**. The app calls it directly:
  - `POST https://api.lemonsqueezy.com/v1/licenses/activate` with `license_key`,
    `instance_name` -> returns `instance.id` (store it).
  - `POST https://api.lemonsqueezy.com/v1/licenses/validate` with `license_key`
    and `instance_id` -> returns `valid` (bool), `error`, and
    `license_key.status` (`inactive` | `active` | `expired` | `disabled`) plus
    `expires_at`.
  - `POST .../v1/licenses/deactivate` with `license_key`, `instance_id` (used when
    removing the license from a device).
  - Headers: `Accept: application/json`, `Content-Type:
    application/x-www-form-urlencoded`. Rate limit 60/min.
- **Key fact:** when a subscription lapses, Lemon Squeezy auto-flips the license
  key `status` to `expired` and `valid` becomes false. So one validate call is
  the entire entitlement signal. `expires_at` is the subscription's paid-through
  date.
- Activation limit (devices per subscription) is set in the Lemon Squeezy
  dashboard; suggested 3.

## User-facing behavior (the requirements, precisely)

1. **Adding Twitter shows a paid + consent dialog** before anything connects:
   - States it is a paid source, $19.95/mo.
   - Required checkbox, exact copy: *"I agree this source shares personal
     information with the app maker, such as your Twitter handle and how many
     times you sync. Your content is never shared."*
   - Cannot proceed unless the box is checked AND entitlement is active.
   - If not entitled: a **Subscribe ($19.95/mo)** button opens the Lemon Squeezy
     checkout in the browser, plus an **"I already have a license key"** paste
     field that activates the key.
   - If entitled: **Continue** proceeds to the existing Twitter OAuth connect.
2. **Only entitled users can add a Twitter sync** (the dialog above is the gate).
3. **Lapsed users' Twitter syncs go inactive** — shown as inactive with a reason,
   config preserved. Re-subscribing reactivates them. Non-Twitter syncs never
   change.
4. **Daily entitlement check at 00:00 America/Los_Angeles**, plus on app launch.
5. **Clicking an inactive paid sync** opens a "reactivate / pay" dialog instead of
   the editor.
6. **Usage event on every Twitter sync** that fires regardless of the analytics
   opt-out (it is billing/abuse metering, consented at step 1).

## Architecture

New shared object **`EntitlementManager`** (`ObservableObject`, created in
`AppDelegate` like `Ledger`, injected into `MainShellView`, `SyncCoordinator`,
and the add/edit views). It owns:

- the license key + instance id (Keychain),
- cached entitlement: `status`, `expiresAt`, `lastValidatedAt` (UserDefaults via
  `AppSettings`),
- `isTwitterEntitled: Bool` (derived, see state machine),
- `activate(key:)`, `validateNow()`, `removeLicense()`,
- the daily 00:00 Pacific scheduler + launch check.

New **`LemonSqueezyClient`** (stateless) wraps activate/validate/deactivate with a
stubable `URLSession` (mirror `XAPIClient`/`RealNotionClient` style).

### Entitlement state machine

`isTwitterEntitled` is true iff the last successful validate returned
`valid == true && status == "active"` and `now < expiresAt` (+ small buffer).

- Daily validate refreshes `status`, `expiresAt`, `lastValidatedAt`.
- **Grace on network failure:** if validate cannot reach the server, keep the
  prior state until `expiresAt` passes (expiresAt is the authoritative paid-through
  date, so this is natural grace; a transient outage never locks out a payer).
  Only after `expiresAt` passes with no successful validate do we fail closed.
- **Explicit lapse:** if validate returns `valid == false` or status
  `expired`/`disabled`, go to lapsed immediately.
- States surfaced: `.active`, `.lapsed` (expired/disabled/past expiresAt),
  `.none` (never subscribed). No config is ever mutated; lapse is a derived gate.

### Daily check (00:00 Pacific)

Mirror the `SyncCoordinator.restartTimer()` Task-loop pattern
(`SyncCoordinator.swift:134`). Compute seconds to the next midnight in
`TimeZone(identifier: "America/Los_Angeles")` with `Calendar`, sleep, validate,
reschedule. Also validate on launch and when opening the add-Twitter flow. Keep
the midnight math in a pure, unit-tested helper.

## Usage telemetry (un-disableable)

- `Telemetry.capture` (`Telemetry.swift:94`) gates on `isOptedIn` at line 95. Add
  a `bypassOptOut: Bool = false` parameter; guard becomes
  `guard bypassOptOut || isOptedIn else { return }`.
- Emit after a **successful** Twitter crawl in `XSourceClient.listItems`
  (`XSourceClient.swift`, after `recordSuccess` ~line 107):
  ```
  Telemetry.capture("x.sync.usage", properties: [
      "x_user_id": cfg.accountId,
      "handle": "@\(cfg.username)",
      "stream": cfg.stream.rawValue,
      "pages_fetched": pages,
      "items_synced": items.count,
      "is_initial_sync": isInitial,
      "license_instance_id": <instance id, to map usage -> subscriber>
  ], bypassOptOut: true)
  ```
- This event fires only for Twitter syncs, which the user consented to at add
  time. All other telemetry stays opt-in.

## Consent / paywall UX

New `TwitterPaywallSheet` (model the existing `.sheet` pattern, e.g.
`AddSourceSheet.swift:68`). Inserted in `AddSourceSheet.connectX`
(`AddSourceSheet.swift:216`) before the OAuth `Task`. Same sheet (or a thin
`ReactivateSheet`) is shown when an inactive paid sync is clicked. Contents:

- Heading + price line.
- Required consent checkbox with the exact copy above.
- Entitled -> Continue (to OAuth). Not entitled -> Subscribe button (opens
  `AuthSecrets.lemonSqueezyCheckoutURL` in the browser) + license-key paste field
  -> `EntitlementManager.activate(key:)`.
- A privacy-policy link (URL the user must host; see manual setup).

## Gating points

- **Add gate:** the paywall sheet in `AddSourceSheet` — cannot reach `connectX`
  OAuth without consent + active entitlement.
- **Run gate:** in `SyncCoordinator.runRule` (`SyncCoordinator.swift:214`), before
  `source.listItems`, skip `.x` rules when `!entitlement.isTwitterEntitled` and
  record a skip reason (new `RuleRunStatus`/event case, e.g. "Twitter sync paused
  — subscription inactive").
- **Row gate:** in `SyncsHomeView` row `onTap` (`SyncsHomeView.swift:211`), for an
  `.x` flow when not entitled, present the reactivate dialog instead of
  `onEdit(flow)`. Show the row visually inactive with the reason. `SyncFlow` is a
  pure struct, so consult `EntitlementManager` from the row view, not inside
  `SyncFlow`.

## Storage

- **Keychain** (`KeychainStore.Key`, add cases):
  `lemonSqueezyLicenseKey -> "lemonsqueezy.license_key"`,
  `lemonSqueezyInstanceId -> "lemonsqueezy.instance_id"`.
- **AppSettings / UserDefaults:** `twitterEntitlementStatus` (String),
  `twitterEntitlementExpiresAt` (Date?), `twitterLastValidatedAt` (Date?).
- **Config (not secret):** `LEMONSQUEEZY_CHECKOUT_URL` in Doppler `sync-bar`,
  added to `Secrets.xcconfig.example`, `scripts/pull-secrets.sh`, `Info.plist`,
  and `AuthSecrets` (`lemonSqueezyCheckoutURL`). No API key is required.

## Privacy

- Update the Settings analytics row copy (`SettingsView.swift:80`, currently
  "Never any personal data") to: general analytics stays anonymous and optional;
  paid Twitter usage metering (handle + sync counts) is separate, required for the
  paid source, and consented when the source is added.
- Add a Settings subscription/license section: status, manage subscription (Lemon
  Squeezy customer portal URL), paste/replace key, remove license (deactivates the
  instance), privacy-policy link.

## Files

**New:**
- `Source/Services/LemonSqueezyClient.swift`
- `Source/Services/EntitlementManager.swift`
- `Source/Views/TwitterPaywallSheet.swift` (and reactivation reuse)
- `Tests/LemonSqueezyClientTests.swift`, `Tests/EntitlementManagerTests.swift`
  (state machine + midnight math), `Tests/TelemetryBypassTests.swift`

**Edit (file:line anchors from the seam map):**
- `Source/Services/Telemetry.swift:94` — `bypassOptOut` param.
- `Source/Services/Sources/XSourceClient.swift:~107` — emit `x.sync.usage`.
- `Source/Services/SyncCoordinator.swift:214` — run gate for `.x`; inject
  `EntitlementManager`.
- `Source/Views/AddSourceSheet.swift:216` — paywall consent before connect.
- `Source/Views/Design/SyncsHomeView.swift:211` — inactive-sync click intercept +
  inactive visual.
- `Source/Views/Design/SyncFlow.swift:36` — entitlement-aware status surfaced via
  the row view.
- `Source/Services/KeychainStore.swift:27` — license + instance keys.
- `Source/Models/AppSettings.swift` — entitlement persistence.
- `Source/Services/AuthSecrets.swift` + `Info.plist` + `Secrets.xcconfig.example`
  + `scripts/pull-secrets.sh` — `LEMONSQUEEZY_CHECKOUT_URL`.
- `Source/Views/SettingsView.swift:80` — privacy copy + subscription section.
- `Source/App/AppDelegate.swift` — create + start `EntitlementManager`; inject.

## Manual setup the user must do (not code)

1. Lemon Squeezy: create the store, a **$19.95/mo subscription** product/variant
   with **license keys enabled**, set the activation limit, and copy the
   **checkout URL** + customer-portal URL. Put `LEMONSQUEEZY_CHECKOUT_URL` in
   Doppler `sync-bar`.
2. Write and host a **privacy policy** (personal data is now collected) and link
   it in the consent sheet and Settings.
3. Decide the device activation limit.

## Out of scope (future)

- Usage-based / metered billing (Lemon Squeezy MoR is flat-rate; would require
  Stripe). The `x.sync.usage` event already captures the data to inform it later.
- Proxying X calls through a server for authoritative (non-trust-based) metering.
