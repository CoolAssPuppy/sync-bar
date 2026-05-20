# Plan: real integrations + brand assets + docs (v0.2)

Decisions (confirmed with user 2026-05-20):
- OAuth secrets live in Doppler project `sync-bar`; extracted at build time. README documents the exact keys; user creates the project + adds keys.
- reMarkable: full pipeline now, including sync/v3 walk + `.rm` -> PNG rasterization (high risk; validate against device when it arrives).
- Linear: replace the personal-access-token field with OAuth.
- Google Docs: documented only (dev-app setup); stays mock for now.
- One commit per integration. Tests for each. Keep all tests green; strict-concurrency clean.

## Commit sequence

- [ ] 1. Brand logos: add notion/linear/apple-notes/google SVGs to Images.xcassets/Destinations/*.imageset (Preserve Vector Data).
- [ ] 2. README.md first pass (overview, architecture, build/test/run, status, integration matrix).
- [ ] 3. OAuth foundation:
      - gitignored Secrets.xcconfig (+ Secrets.xcconfig.example), scripts/pull-secrets.sh (doppler download, project sync-bar)
      - project.yml wiring + Info.plist build-var mapping + AuthSecrets accessor
      - reusable OAuthService over ASWebAuthenticationSession (scheme syncnerds://oauth/<provider>), state/PKCE
      - AppDelegate URL handling if needed; graceful "not configured" fallback so build/tests pass without keys
- [ ] 4. Apple Notes: entitlements (NSAppleEventsUsageDescription + automation.apple-events), harden AppleScript escaping, AddDestinationSheet creates real target+folder, tests.
- [ ] 5. Linear OAuth: LinearAuthService (authorize + token exchange + refresh), keychain (access/refresh/expiry), replace PAT UI, Bearer header in client, tests.
- [ ] 6. Notion OAuth: NotionAuthService (authorize + Basic-auth token exchange -> bot token + workspace), replace connectMockWorkspace, store bot token, connect UI, tests.
- [ ] 7. reMarkable: RealRemarkableClient sync/v3 index walk (listNotebooks/listPages), blob download, .rm v6 parser + CoreGraphics renderer -> PNG, wire imageData(for:), swap real client in, tests with fixtures.
- [ ] 8. README OAuth/dev-app setup: how to register apps in Notion, Linear, Google; redirect URIs; scopes; exact Doppler keys for project sync-bar.

## Doppler keys (project sync-bar) — finalize in step 8
- NOTION_CLIENT_ID, NOTION_CLIENT_SECRET
- LINEAR_CLIENT_ID, LINEAR_CLIENT_SECRET
- GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET (documented; Google stays mock)
- reMarkable: none (device one-time-code pairing).

## Notes / risks
- reMarkable rasterization can't be fully validated until the device is in hand; expect iteration against real .rm files.
- OAuth flows are code-complete but only authenticate once Doppler keys + registered developer apps exist.
