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

(to be filled in as commits land)
