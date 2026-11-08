# Todo

## Release gate and selector containment

### Plan
- [x] Keep the theme swatch animation within the Appearance card, with less overshoot and a clipped card boundary.
- [x] Repair seven small existing SwiftLint errors without changing behavior.
- [x] Move independent editor types and controls to their own files, and split the editor's save helpers into a same-file extension to satisfy length rules.
- [x] Run full `make test`, `make lint`, and `make build` on the final files, and preserve the installed app.
- [x] Commit, fast forward main, and push the reviewed release files.

### Review
- Final release-file gate passed: `make test` ran 450 tests with no failures (`/tmp/sync-bar-release-final-test.log`, `build/Logs/Test/Test-SyncBar-2026.11.08_07-51-19-+0000.xcresult`); `make lint` exited 0 (`/tmp/sync-bar-release-final-lint.log`); `make build` exited 0 (`/tmp/sync-bar-release-final-build.log`); `git diff --check` passed. The installed app was reopened after tests.
- The live R2 appcast lists version 1.7.0, build 32, and "Some UI cleanup." The DMG returned HTTP 200 with `Content-Length: 8767312`, matching its appcast enclosure. The parent agent verified the public shortlink `https://coolasspuppy.com/syncbar-updates` resolves to the same feed. The old `downloads.strategicnerds.com` hostname did not resolve from this machine; the active shortlink and R2 feed work.
- The 1.7.0 changelog entry uses the requested note: "Some UI cleanup."

## Compact theme selector

### Plan
- [x] Replace the Settings menu picker with a compact selector showing the active name and swatch at the right edge.
- [x] Expand theme swatches to the left on hover or click, select a theme, and collapse with spring motion unless Reduce Motion is enabled.
- [x] Give each theme a named keyboard and VoiceOver control, with a keyboard path to expand and collapse the selector.
- [x] Check Swift syntax and the diff locally; coordinate the Xcode build and live UI check with the parent agent.

### Review
- Reused the existing theme store and swatch colors. The active button opens or closes the choices, each theme is a named button, and Escape closes them.
- `swiftc -frontend -parse` and `git diff --check` passed. These checks do not prove SwiftUI type checking or visual behavior.
- No new isolated test was added for this visual interaction. The final build passed, and the user reviewed the picker before release.

### Selection and keyboard follow-up
- [x] Animate the selected swatch from its choice position to the active position.
- [x] Put the active button before choices in keyboard order while keeping it at the right edge.
- [x] Check Swift syntax and accessibility labels before the Xcode build handoff.

`matchedGeometryEffect` connects each choice swatch to its active position. A right-to-left swatch row keeps the trigger visually on the right and first in source order for keyboard focus. Syntax parsing and `git diff --check` passed; live motion and focus behavior still need review.

## UI cleanup (cleanup-ui)

### Plan
- [x] Simplify the menu bar popover header and footer while preserving sync, pause, upload, Settings, theme, and Quit actions.
- [x] Move theme choice into Settings and make its sections easier to scan in one column.
- [x] Remove repeated decoration and copy from the Settings drawer.
- [x] Check the affected screens in the running app and save screenshots.
- [x] Run the full local test, lint, and build commands, save logs, and review the final diff.

### Review
- `make build` passed on 2026-11-08.
- `make test` passed all 450 tests after temporarily stopping the installed Sync Bar app, which shared the test runner's bundle identifier. The installed app was reopened. See `/tmp/sync-bar-ui-test-retry.log` and `build/Logs/Test/Test-SyncBar-2026.11.08_06-44-32-+0000.xcresult`.
- An earlier `make lint` run found nine existing errors. They were repaired before the 1.7.0 release, and the final lint run passed.
- Main window, Settings, and dropdown content screenshots are in `/Users/prashant/.codex/visualizations/2026/11/08/01a1b9c1-dfc3-7aa1-8a2e-b771e8dc5c85/screenshots`. The dropdown uses a temporary preview window; direct menu bar placement still needs checking. Preview code was removed, the normal build passed, and the installed app and saved settings were restored.

# De-reMarkable the Syncs screen

## The bug, as observed

State: `ledger.remarkableAccount` is nil, no Safari, no Reminders. Connected sources
are one Notion workspace (as a backup source) and one Twitter account. Four rules in
`ledger.rules.v2`, three of them with destinations, so `ledger.syncFlows.count == 3`.

Two independent defects, both from the era when reMarkable was the only source:

1. `SyncsHomeView.hasAnySource` (SyncsHomeView.swift:106) counts only reMarkable,
   Safari, and Reminders. Notion and Twitter sources don't register, so `content`
   takes the `!hasAnySource` branch and draws the "Add your first Source" hero
   *instead of the list*. The rail badge still reads "3", so the window contradicts
   itself. `SyncEditorView.availableSources` (SyncEditorView.swift:162) already has
   the correct list; the home screen has its own stale copy.
2. `disconnectedBanner` (SyncsHomeView.swift:114) shows whenever
   `ledger.remarkableNeedsRepair` is true, with no check that a reMarkable is even
   paired. A leftover device token in the keychain gets rejected by the cloud, the
   flag latches, and a user who sold their tablet gets told to "re-pair in
   Connections" — where there is no reMarkable card to act on, because
   `remarkableAccount` is nil. A dead end.

Related, found while tracing (same root cause, worth fixing in the same pass):

3. `Ledger.connectedSourceCount` (SyncFlow.swift:104) omits `xAccounts`, so the
   Connections badge undercounts by one per connected Twitter account.
4. `MainShellView.refreshFolders()` (MainShellView.swift:156) has no device-token
   guard, unlike `SyncCoordinator.refreshFolders()` which does. With no token,
   `RemarkableClientFactory.make()` returns the mock client, and the shell writes
   its sample folders (Work / Personal / Projects) into the ledger and reconciles
   real rules against them. Reachable from onboarding finish and
   `.remarkableUploadFinished`. Verified this ledger is clean — the four cached
   folders are real — but the path is live.
5. Copy: the empty state ("A sync sends one reMarkable folder to one app") and the
   hero subtitle ("your reMarkable, or Safari bookmarks") describe a
   reMarkable-only app. `Sources.swift`'s header comment says reMarkable is the
   only source, which is four sources out of date.

## Commit order (build + `make test` green between each)

- [x] 1. `Ledger.hasAnySource` / `connectedSourceKinds` as the single source of
      truth; `SyncsHomeView.hasAnySource` and `SyncEditorView.availableSources`
      both derive from it. `connectedSourceCount` counts Twitter accounts.
      Fixes the hidden syncs and the badge. (`ff6e96e`)
- [x] 2. `setRemarkableNeedsRepair` can't latch true with nothing paired,
      unpairing lowers it, and `SyncCoordinator.refreshFolders` requires an
      account rather than just a token. Fixes the dead-end banner. (`decbb80`)
- [x] 3. Device-token guard in `MainShellView.refreshFolders`, so the mock
      client's sample folders can never reach the ledger. (`83c7f65`)
- [x] 4. Source-agnostic copy in the empty state and hero; drop the unused
      `onRefresh` parameter; refresh two stale header comments. (`e6cf1f2`)
- [x] 5. `howSummary` stops reporting title strategy and OCR mode for sources
      that have neither. Found in the verification screenshot: a Notion backup
      row read "First line as title · OCR all pages". (`32cc881`)
- [x] 6. Rename the Notion source's "Folder column" label to "Folder from",
      which is what the dropdown does. (`62a1dfb`)

## Review

Branch `fix-syncs-screen-remarkable-assumption`, six commits, `make build` and
`make test` green between each (450 tests, 0 failures). Not pushed.

Verified against the real ledger, not a fixture: the Syncs screen now lists all
three syncs (two Notion groups and one Twitter) with no banner, and the
Connections badge reads 3, matching the cards on that screen.

Root cause of both defects was the same shape: reMarkable-era checks that were
never widened when Notion and Twitter became sources. The fix consolidates the
"which sources exist" question into `Ledger` so the next source added can't
reintroduce the drift — the home screen and the editor had already drifted.

Not changed, worth knowing:

- Two `Notes -> Markdown files` rows were indistinguishable in the list, because
  a row shows source and destination kind but nothing that separates two syncs
  sharing both. One of them has since been deleted from the ledger (not by this
  work — nothing here deletes rules).
- The Markdown destination's file-name-template hint offers `{folder_name}`,
  which resolves to the *database title* for a Notion source, not the Folder
  column. `{folder_name}/{date}-{title}` therefore writes
  `Category/Notes/<date>-<title>.md` — a redundant level, since the Folder
  column already becomes the leading subfolder on its own.
- `make lint` still exits non-zero on the pre-existing `force_try` in
  `NotionPageReaderTests.swift`.
