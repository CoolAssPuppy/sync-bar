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
