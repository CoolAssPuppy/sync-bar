# Paid Twitter source — implementation plan

## Decisions (supersede the original spec)

- **Provider: Polar.sh** (not Lemon Squeezy). License-key *validate* needs no auth and
  is safe in the client (`POST /v1/customer-portal/license-keys/validate`, body `key`
  + `organization_id`). Event ingestion (metered) needs an Organization Access Token,
  so it runs through a small server-side relay.
- **Billing: $4.99/month flat base + metered usage.** The flat base (a Polar
  subscription with a License Keys benefit) is the entitlement gate. Every tweet read
  is metered and billed (not overage — usage from read #1).
- **X cost reality:** pay-per-use, $0.005 per post read, 2M reads/mo cap, 24h dedup.
  The app already counts reads, so metered billing is fair and computable.

## Architecture for optionality (per user directive)

Twitter is the FIRST instance of a general "paid Sync class". Gate via a `PaidFeature`
abstraction, not hardcoded `.x` checks:

- `PaidFeature` enum (currently `.twitter`); map a `SyncRule`/`SourceKind` -> `PaidFeature?`.
- `LicenseProvider` protocol; `PolarLicenseClient` is one conformer (swappable).
- `EntitlementManager` owns the state machine, daily check, grace via `expires_at`.
- Gates ask "does this sync belong to a paid class, and is that class entitled?"

## Commit order (build + `make test` green between each)

- [ ] 1. Docs: this plan + spec decisions header.
- [ ] 2. Config plumbing: `POLAR_ORG_ID`, `POLAR_CHECKOUT_URL`, `POLAR_PORTAL_URL`,
      `POLAR_USAGE_RELAY_URL` through xcconfig.example, pull-secrets.sh, project.yml,
      Info.plist, `AuthSecrets`. Keychain keys `licenseKey`, `licenseActivationId`.
- [ ] 3. Telemetry `bypassOptOut` param + `TelemetryBypassTests`.
- [ ] 4. `LicenseProvider` protocol + `PolarLicenseClient` + `PolarLicenseClientTests`.
- [ ] 5. `PaidFeature` + `EntitlementManager` (state machine + pure midnight helper)
      + AppSettings persistence + `EntitlementManagerTests`.
- [ ] 6. Inject `EntitlementManager` in `AppDelegate`; thread to coordinator + views.
- [ ] 7. `x.sync.usage` emit in `XSourceClient.listItems` (bypassOptOut) + `UsageReporter`
      (posts reads to the Polar relay; no-ops when the URL is unset).
- [ ] 8. Run gate in `SyncCoordinator.runRule` (skip `.x` when not entitled, clear skip).
- [ ] 9. `TwitterPaywallSheet` + add gate in `AddSourceSheet.connectX`.
- [ ] 10. Inactive-sync row + reactivate dialog in `SyncsHomeView`.
- [ ] 11. Settings subscription/license section + privacy copy.
- [ ] 12. Relay scaffold (`polar-relay/`) for the user to deploy.

## Manual setup the user owns

- Polar org + $4.99/mo subscription product with License Keys benefit + a metered price,
  a Meter on `x.sync.usage` reads, checkout + portal URLs, Org ID -> Doppler `sync-bar`.
- Deploy the relay (holds the Org Access Token) -> `POLAR_USAGE_RELAY_URL` in Doppler.
- Host a privacy policy; swap the placeholder URL.

## Review

All 12 commits landed on branch `paid-twitter-source`, building green with `make build`
and `make test` (388 tests, 0 failures) between each. Not pushed.

What shipped:
- Provider-neutral entitlement layer (`LicenseProvider` + `PolarLicenseClient`), so the
  subscription provider stays swappable.
- `PaidFeature` abstraction (Twitter = first instance) — every gate routes through it,
  never a bare `.x` check, so a future paywall over another sync or a group is a data
  change in `PaidFeature.sourceKinds`, not a sweep.
- `EntitlementManager`: state machine with grace via `expiresAt`, daily 00:00 Pacific
  re-check + launch check, pure unit-tested midnight + reduce/isEntitled helpers.
- Un-disableable `x.sync.usage` (telemetry `bypassOptOut`) + best-effort `UsageReporter`
  to the metered-billing relay.
- Gates: add (paywall before OAuth), run (skip lapsed paid rules), row (inactive +
  reactivate dialog). Settings subscription section + honest analytics copy.
- `polar-relay/` scaffold for the metered-billing endpoint (user deploys).

Deviation from the original spec, by user decision: provider is Polar (not Lemon
Squeezy); pricing is $4.99/mo base + metered usage (not $19.95 flat). Entitlement
persistence lives in `EntitlementManager` (keyed by feature) rather than three
Twitter-specific `AppSettings` fields, for optionality.

Manual setup still owned by the user (flagged, stubbed in code):
- Create the Polar org + $4.99/mo product (License Keys benefit) + Meter + metered price;
  put `POLAR_ORG_ID`, `POLAR_CHECKOUT_URL`, `POLAR_PORTAL_URL` in Doppler `sync-bar`.
- Deploy `polar-relay/`, set `POLAR_USAGE_RELAY_URL` in Doppler.
- Host a privacy policy; replace the placeholder `AuthSecrets.privacyPolicyURL`.

Not verifiable without that setup: live activation, checkout, portal, and metered
ingestion (the entitlement state machine, gates, and parsing are unit-tested against
Polar's documented response shapes).

Pre-existing lint note: `make lint` exits non-zero on a `force_try` in
`NotionPageReaderTests.swift` (on `main`, untouched here). New code adds only
force-unwrap warnings in tests, matching the existing test-suite convention.
