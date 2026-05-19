# Changelog

## 0.1.0 — 2026-05-19

Initial overnight build. Visual shell, mock-backed services, working sync cycle, theming, persistence, settings, and onboarding.

### Added
- Menu bar status item with click-to-popover and right-click menu.
- Menu bar popover showing configured sync rules with last run time and result.
- Main window with sidebar (accounts, navigation, gear), notebook list, slide-up rule sheet, sync log, workspace and reMarkable detail screens.
- Top-down Settings drawer with six cards: General, OCR, Accounts, Notifications, Data, Advanced.
- Three-step onboarding (welcome, pair reMarkable, connect Notion).
- 10-theme palette ported from mail-notifier (System, Hoth, Risa, Weasley, Starbuck, Cylon, Vader, Kirk, Hermione, Nerds).
- `SyncCoordinator` with background timer at user-configurable intervals.
- `RulesEngine` with title strategies and skip reasons; XCTest happy-path coverage.
- `Ledger` persistence to UserDefaults for accounts, rules, events, notebooks.
- `KeychainStore` over KeychainAccess for OpenAI / Anthropic / reMarkable / Notion secrets.
- XcodeGen-driven project, Makefile, and `scripts/` directory.

### Deferred to 0.2
- Real reMarkable cloud client.
- Real Notion OAuth.
- Vision / OpenAI / Anthropic OCR calls.
- CloudKit private database storage.
- Sparkle signed appcast release pipeline.
- Snapshot and UI test coverage.
- Final app icon set.
