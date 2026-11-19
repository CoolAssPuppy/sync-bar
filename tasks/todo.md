# Todo

## UX overhaul: make every control say what it did

Outcome: you can always tell whether SyncBar is paused, syncing, failing, or idle, and every button either does something visible or says why it can't.

Source: two code audits on 2026-11-19 (menu bar and sync controls; main window), with the high-severity claims checked against the code. Today's failure: syncing was paused since Nov 8, "sync now" clicks were dropped silently, and resume started nothing.

### Decisions needed before building
- [x] D1. "Sync now" while paused runs anyway. Pause stops only the timer. (chosen 2026-11-19)
- [x] D2. Two-way syncs go on the 15-minute timer and follow Pause. (chosen 2026-11-19)
- [x] D3. Build all four phases, one commit each. (chosen 2026-11-19)

### Phase 1. One visible sync state (today's bug)
- [x] One `SyncStatus` value (paused, syncing, failed, idle with last and next run) built from both coordinators. The popover header, main window header, menu bar icon, and tooltip all read it. Isolated table tests first, from a written failure list.
- [x] Bring back the "Paused" pill and warning dot. Add a paused banner with Resume to the Syncs screen.
- [x] Resume starts a sync right away.
- [x] "Sync now" while paused follows D1. Sync buttons disable and spin while a run is active. A click during a run says "Already syncing".
- [x] Task syncs follow Pause, set their busy state, and animate the menu bar icon.
- [x] Menu bar icon: paused and failed badges. The tooltip states the status.
- [x] Popover and main window rows show "Failed", "Off", or "Inactive" in place of "Synced X ago" when that applies.

Phase 1 notes: isolated tests (SyncStatusTests, failure list O1-O18 and R1-R11) were written first and seen failing. The menu bar icon dims while paused, shows a red dot while a sync has failed, and its tooltip and right-click menu show the overview line. E2E: `scripts/ux-shots.sh build/ux-shots/phase-1` renders the real popover and Syncs screen offscreen (paused, idle with failure, syncing) from the isolated test ledger. A fresh reviewer read the renders. Fixed from that review: partial failures counted in the header, no repeated "Paused", the subtitle colors only the status, and errors wrap to two lines in the popover. Not changed: paused and partial share the warning color (syncing is shown by the spinning button).

### Phase 2. Errors you can reach
- [x] A source failure (for example "Reconnect the Notion workspace") marks its syncs Failed and posts the failure notification.
- [x] A Failed row shows the one-line error. Clicking it opens Activity filtered to that sync.
- [x] Task sync errors write an Activity event.
- [x] Connections: Reconnect errors appear on the card. Notion, Linear, Google, and Twitter get a "Needs reconnect" state.
- [x] Editor pickers that fail to load show the error and a Retry button. Today they say "Loading..." forever.
- [x] Upload from the menu bar opens a file picker. Today it opens a tab with no upload control.
- [x] Activity: add a "Skipped" filter. Skip rows say "Skipped". The empty state tells "no events" apart from "filter hides events".
Phase 2 notes: two behavior tests written first and seen failing (source listing failure marks every enabled binding failed; a task sync with no provider logs a failed event). An account card turns red with the latest error and a Reconnect button when any of its syncs failed (derived from sync results, since token health isn't stored for most accounts). E2E renders in `build/ux-shots/phase-2/` (Connections with a failure, Activity filtered to one sync, Activity with no match).

### Phase 3. A safe editor
- [x] Confirm Delete. Ask before Close or Cancel discards edits.
- [x] A greyed-out Save names the missing field.
- [x] Add an on/off switch for each sync. Today "Off" can show, but nothing turns it off or on.
- [x] "Template" title option: add the template field, or remove the option.
- [x] Warn when a change will rewrite every note on the next run.
Phase 3 notes: "Template" now shows only for a sync already using it (no editor for the template text exists). The editor was split (save and delete moved to SyncEditorView+Save.swift; picker loading to PickerLoadTracker) to stay under the lint size limits. Found by the edit render: opening and saving an older Markdown sync forced a full rewrite because an unset frontmatter mode compared unequal to the explicit one the editor writes back. Fixed in `DestinationConfiguration.hasSameSettings`, test written first. Also fixed: saving an edited two-way sync wiped its created date and last-run status.
Known issue, not fixed in this pass: the Notion mapping loader drops dateSource, checkbox, number and literal mappings, so saving a Notion sync that has them deletes them. The user's data has no Notion destinations today.

### Phase 4. Cleanup
- [ ] Delete unreachable views (DestinationDetailScaffold, BindingEditorSheet, FolderPickerSheet, NotionForm, OnboardingView, SyncRuleCard, DestinationIconStack), and check each has no caller first.
- [ ] Copy pass with the terse rule: cut helper paragraphs, and drop "rule", "ledger", "orphans", "OAuth", and the CASA joke from the UI.
- [ ] Use one sync icon, one button set, one status pill, and one sync row view for one-way and task syncs.

### Not in this pass
- Splitting the 1,487-line SyncEditorView into a draft model and subviews. It's worth doing, but it's a refactor with its own risk.
- Settings that are stored per folder and shared by sibling syncs (notebook choice, page order, attach PDF).

### Verification
- `make test`, `make lint`, `make build` after each phase, one commit per phase.
- There is no UI test target. Each phase ends with `make run` and screenshots of every changed state (paused, syncing, failed, idle) saved to `build/ux-shots/phase-N/`. A fresh subagent that has not seen this plan reviews the screenshots against the outcome line.

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
