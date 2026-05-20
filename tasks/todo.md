# Plan: real integrations + brand assets + docs (v0.2)

Decisions (confirmed with user 2026-05-20):
- OAuth secrets live in Doppler project `sync-bar`; extracted at build time. README documents the exact keys; user creates the project + adds keys.
- reMarkable: full pipeline now, including sync/v3 walk + `.rm` -> PNG rasterization (high risk; validate against device when it arrives).
- Linear: replace the personal-access-token field with OAuth.
- Google Docs: documented only (dev-app setup); stays mock for now.
- One commit per integration. Tests for each. Keep all tests green; strict-concurrency clean.

## Commit sequence

- [x] 1. Brand logos: SVGs into Images.xcassets/Destinations/*.imageset (Preserve Vector Data).
- [x] 2. README refresh (the repo already had a detailed one; updated stale parts + added OAuth section).
- [x] 3. OAuth foundation: Secrets.xcconfig (+example) + pull-secrets.sh, Info.plist build-var mapping, AuthSecrets, OAuthWebSession + OAuth helpers, graceful not-configured fallback.
- [x] 4. Apple Notes: automation entitlement + NSAppleEventsUsageDescription, CR-safe escaping, testable script builder.
- [x] 5. Linear OAuth: LinearAuthService (custom-scheme ASWebAuthenticationSession), PAT field removed, Bearer header.
- [x] 6. Notion OAuth: NotionAuthService over a loopback HTTP listener (Notion rejects custom schemes), bot-token storage.
- [x] 7. reMarkable: sync index walk + .rm v6 parser + CoreGraphics renderer, RemarkableClientFactory, imageData wired.
- [x] 8. README OAuth/dev-app setup: Notion/Linear/Google registration, redirect URIs, scopes, Doppler keys.

## Review (2026-05-20)

All eight steps committed one-per-integration; 65 tests green; app launches.
Notes for the next session:
- reMarkable cloud endpoints and v6 stroke field layout are reverse-engineered
  and unvalidated; parsers are unit-tested in isolation but the live walk and
  rendering need device iteration.
- OAuth flows are code-complete but only authenticate once the user creates the
  developer apps and adds the keys to the Doppler `sync-bar` project.
- Google Docs OAuth is documented only; its client is still mock.

## Doppler keys (project sync-bar) — finalize in step 8
- NOTION_CLIENT_ID, NOTION_CLIENT_SECRET
- LINEAR_CLIENT_ID, LINEAR_CLIENT_SECRET
- GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET (documented; Google stays mock)
- reMarkable: none (device one-time-code pairing).

## Notes / risks
- reMarkable rasterization can't be fully validated until the device is in hand; expect iteration against real .rm files.
- OAuth flows are code-complete but only authenticate once Doppler keys + registered developer apps exist.
