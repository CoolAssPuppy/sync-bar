# Build lessons and contradictions

## 2026-05-23 verify UI changes by running, not just building

- **Correction from the user:** I shipped visual changes (a reMarkable logo, "broken Notion") to 0.4.0/0.4.1 having only run `make build` + `make test`. The tests don't cover views, so a flattened logo and a token-dependent dropdown slipped through. Lesson: for any UI/visual or integration change, launch the app and look (`make run` then `screencapture`), don't declare it done off a green build alone.
- **Asset gotcha:** the bundled `Remarkable` PNG is opaque (RGB, no alpha). `renderingMode(.template)` flattens an alpha-less image to a solid tinted square. Check `file *.png` for "RGBA" before template-tinting; render opaque marks as-is (e.g. on a small white chip).
- **Token-dependent UI fails silently after a keychain change:** moving to the data-protection keychain (0.4.0) wiped OAuth tokens, so `NotionClientFactory` fell back to the mock (empty dropdown) and Google showed "expired" — with no reconnect UI. Any keychain-store change needs a re-auth path (added Reconnect to the account gear drawer).
- **Screenshot caveat:** `screencapture` on a locked Mac returns the lock-screen clock, not the app. `caffeinate -u` wakes the display but can't unlock; if `pgrep loginwindow ... console` shows the lock screen, ask the user to unlock before relying on a screenshot.

## 2026-05-19 overnight build

### Choices made under time pressure

- **Single-target app vs Swift Package modules.** The spec asked for `RemarkableKit`, `NotionKit`, `OcrKit`, `RulesEngine`, `SyncCore`, `LedgerKit`, `KeychainKit`, `DesignSystem` packages. Splitting these out adds a workspace, eight `Package.swift` files, and a lot of XcodeGen wiring before any feature code lands. We kept the logical separation as folders under `Source/` for v0.1. Moving each folder behind an SPM target later is a mechanical refactor because no internals leak across the boundary.
- **UserDefaults instead of CloudKit.** CloudKit needs an entitlement we can sign for, a container ID provisioned in App Store Connect, and a schema migration story. For v0.1 the `Ledger` API matches what a CloudKit implementation needs (upsert, list, delete, append events) but persists into `UserDefaults`. CloudKit lands when we wire up signing.
- **Mock clients are the default.** The reMarkable device hasn't arrived and Notion OAuth needs a registered integration. `MockRemarkableClient` and `MockNotionClient` ship as the live clients so the UI is exercisable. The real clients drop in by changing two lines in `SyncCoordinator`.

### Things that surprised me

- The first run sometimes returns "no main window" via accessibility queries while the screen is locked. The window is actually created (verified via `window.isVisible == true`); macOS just doesn't expose locked-screen window trees through `AXChildren`. No code change needed for the user; once the screen is unlocked, the window appears.
- Adding `DispatchQueue.main.async` around the initial `showMainWindow()` call helped consistency on launch when the screen had just unlocked. Without it the window sometimes didn't paint until a second click.
- `@MainActor` plus `@objc` on AppDelegate methods works fine for Swift 5.9 but throws Swift 6 warnings about main-actor-isolated `shared` properties referenced from nonisolated contexts. We accept the warnings for now.

### Open questions for the human

- Should the menu bar icon spin while syncing, or pulse, or just swap to a "checking" SF Symbol variant? Today it spins via CALayer rotation. Easy to flip.
- Do we want the popover to also show the next scheduled sync time as part of the rule card, or just last run? Today the header shows "Next 4:32 PM" when nothing has run yet, and "Last run 4:17 PM" once it has.
- Is the 6-card Settings layout right for the drawer (General + OCR + Accounts in one column, Notifications + Data + Advanced in the other)? That's how mail-notifier organises it.

### Lesson: tests must be hermetic against the developer keychain (2026-07-10)

A coordinator test decoded the production Twitter rule verbatim (real Notion
workspace + database ids) and relied on the "no token -> mock client" branch.
But the test host shares the developer's keychain, so the live workspace token
WAS found and every `make test` run created real "tweet one/two" pages in the
user's Read it Later database. The user found the junk rows in Notion.

Rules going forward:
- Never put real workspace/database/account ids in test fixtures; fake ids
  cost nothing and make the no-token mock path certain.
- Inject a spy destination whenever the coordinator runs in a test; do not
  rely on a downstream client's own mock fallback for hermeticity.
- Destination clients now hard-refuse real network writes under XCTest
  (NSClassFromString("XCTestCase") guard in NotionDestinationClient); add the
  same guard to any future destination client that reads shared credentials.
