# Plan: source -> destination connection redesign (v0.3)

Supersedes the v0.2 integrations plan (complete; see git history). Triggered by a
user report that surfaced three real problems:
1. Markdown sync gives you no obvious way to choose the output folder.
2. "Sync now" shows "Syncing now…" then silently does nothing, with no log entry.
3. You can pick reMarkable folders but not individual notebooks (e.g. journal only).

## Decisions (confirmed with user 2026-05-22)

- Three nouns, named explicitly: **Source** (reMarkable folders + documents),
  **Destination** (a connected target carrying a default config), **Connection**
  (one source scope routed to N destinations, with shared note settings).
- **Both flows as peers.** Onboard destination-first (add a destination, configure
  its defaults, then connect a source), but keep a source-first folder/notebook
  browser as a fully supported second view. Both are projections of the same
  connection set.
- **Connection scope is a folder OR specific notebooks.** Folder scope includes
  current and future documents; notebook scope is hand-picked.
- **Guided empty states, no forced wizard.** Each surface shows what is missing
  and the next action; setup is completable in any order.
- **Inherit-then-override config.** A connection inherits the destination's default
  configuration and may override it per connection. Ship inherit-only first.
- One item per commit. `make build` + `make test` green between each. Pkill the app
  before tests. Do not push without an explicit ask.

## Model mapping (what already exists)

- Source: `RmNotebook` is actually a folder (badly named); `RmFile` is the real
  document. `RmFile` already has id/name/folderId/tags. No new source fetch needed
  for notebook scope — `listFiles(inFolderId:)` exists, only the engine uses it.
- Destination: five per-type records (`notionWorkspaces`, `linearAccounts`,
  `googleAccounts`, `markdownTargets`, `appleNotesTargets`). `MarkdownTarget` already
  has `folderPath`; it is just never populated. These ARE the destination objects.
- Connection: `SyncRule` (folder-keyed + shared note settings) + `DestinationBinding`s
  (the only current home of real config). Destination-first projection already
  possible via `Ledger.bindings(matching:)`.

## Two real model changes

A. Destination carries a default `DestinationConfiguration`, captured at creation;
   connection-creation copies it into the new binding instead of from empty.
   - Open impl fork (settle in commit 2): store the default inline on each record
     vs. a side store keyed by destination id. Lean: side store, least invasive,
     no migration of the five record types.
B. `SyncRule.rmNotebookId/Name` -> `source: SourceScope` where
   `SourceScope = .folder(id, name) | .notebooks([{id, name}])`.
   - Needs a backward-compatible decoder: stored rules with only `rmNotebookId`
     decode as `.folder`. Update `rule(forNotebookId:)`, `pruneRules`, idempotency.

## Commit sequence

### Phase 0 — make sync honest (independent, ship first)
- [x] 0. Coordinator writes a visible `cycleSkipped` event at every silent early-return
      on the MANUAL path (no account, paused, no connected folders, rule disabled, no
      destinations, empty folder, tag filter excluded all), naming the folder. Scheduled
      ticks stay quiet (gated on trigger) so an idle account doesn't flood the log.
      Commits a0d7057 + 0f4e092 + 3fb6d49; 6 tests added; 128 green.
      Deferred review findings (not blocking, revisit later):
        - "Already up to date" case still writes only ruleRunStarted/Completed (logged,
          not silent) — could add a friendly "nothing changed" signal.
        - SyncEvent array decode is all-or-nothing; an unknown future event type would
          wipe the cached log on a downgrade. Make decode element-resilient someday.
        - No dedup/rate-limit on repeated identical manual skips (mashing Sync now).
        - `recordSkip` stores the reason in `ruleName` (visible as the row title); fine
          for skips, but a dedicated message field would be cleaner.

### Phase 1 — destinations carry a default config
- [x] 1. Markdown destination creation captures the folder (NSOpenPanel up front) +
      filename template + frontmatter as the destination default; cannot finish
      without a folder. `MarkdownTarget` holds the full config (decode-safe optionals).
      Multiple Markdown folders now allowed, distinguished in sidebar/detail by name+path.
- [x] 2. Quick-add inherits `MarkdownTarget.defaultConfiguration` instead of a blank
      path; binding editor already had the picker. Re-adding a folder updates (not
      duplicates) the destination. Commits 4ed4694 + c2c913c + 0a464a2; 131 green.
- [~] 3. Default-config capture for other types: SKIPPED for now. Notion/Linear/Google
      already create sensible defaults at quick-add and refine in the binding editor;
      they were never broken like Markdown's empty path. Apple Notes defaults to a
      "Sync Bar" folder. Revisit only if these prove confusing.

### Phase 2 — source scope in data + engine
- [x] 4 & 5. DONE via a lower-risk design than the SourceScope rewrite: added an
      optional `SyncRule.selectedFileIds` (nil/[] = whole folder + future docs; a set
      = only those documents) with `includes(fileId:)`/`syncsEntireFolder`. No data
      migration; decode-safe. Coordinator narrows each folder's files by the scope and
      adds a `selectedNotesMissing` skip reason. Commits dce8f0c + 3aa8b4c; 136 green.
      Carry to Phase 3: the folder note-count label still shows the whole-folder count;
      reflect the scoped count once the picker can set selectedFileIds.

### Phase 3 — source tree UI
- [x] 6 & 7. The rule sheet gained a Notebooks card (NotebookScopePicker): "Sync every
      notebook" or uncheck to hand-pick from the folder's documents, writing
      selectedFileIds. Loads the folder's documents via SyncCoordinator.files(inFolder:);
      header shows the scoped count. "Sync only my journal" now works end to end.
      Commits 0b839d6 + 162add7 + 2813186; 136 green.
      Note: hand-pick is folder-scoped (pick within one folder), matching the
      folder-anchored rule model; cross-folder selection is out of scope.

### Phase 4 — both-as-peers + guided empty states
- [x] 8. Destination-first connect: each destination detail has a "Connect a folder"
      action + actionable empty state ("Nothing flows here yet") -> FolderPickerSheet ->
      Ledger.connect(folder:configuration:) finds-or-creates the folder's rule and
      attaches the binding, skipping duplicates and folders already connected here.
      Wired for all five destination types via shared defaultConfiguration accessors.
- [x] 9. Guided empty states: destination-with-no-connections is now an actionable CTA;
      no-reMarkable (pairPrompt) and no-destinations (sidebar/AddDestinationSheet) already
      existed. Commits e7d9f5e + 907dacc + 1c5b219; 139 green.
      Known limitation: OAuth destinations (esp. Notion) connect at a blank default that
      must be refined via the folder's rule-sheet Edit; the destination detail's sync
      rows are read-only (same as the pre-existing source-first quick-add).

### Phase 5 — structural cleanup (done first, per user, to build features on a clean base)
- [x] 11. Rename `RmNotebook` -> `RmFolder` + the folder cache API throughout. Done in
      commit 3b8c65f; folder cache key string + UI copy preserved; 122 tests green.
      (`rmNotebookId/Name` persisted fields and `RmPage.notebookId` left for later.)
- [~] 10. Unify the five destination arrays: DECLINED 2026-05-22. Not worth the risk.
      Scaling check: 30 destination *instances* is fine (tiny arrays, linear lookups,
      no quadratic). 30 destination *types* is also fine at runtime but costs ~13 files
      of per-type boilerplate each (the five parallel `Ledger` arrays are the offender).
      Switches are exhaustive (one `default:` in AddDestinationSheet), so the compiler
      catches every spot — no silent runtime breakage. If the type count ever justifies
      it, collapse only the five `Ledger` arrays into one generic kind-keyed store; that
      is a localized refactor, not a rewrite. Phase 1's default-config home will be a
      small per-destination-id side store, not a unification.

## Notes / risks

- `SyncRule` is Codable-from-UserDefaults; changing its key field breaks decoding of
  existing data unless the decoder reads the legacy `rmNotebookId` fallback. This is
  the highest-risk change; cover it with a decode-old-write-new test.
- Destination-first connection creation needs `SourceScope` equality to find-or-create
  the right rule, and sensible defaults for the rule-level note settings (OCR/title).
- Phase 0 and 1 deliver user-visible fixes immediately and are independent of 2–4.
- Keep strict-concurrency clean; trust `xcodebuild`/`make test` over SourceKit.

## Review (2026-05-22)

All phases landed. Each shipped as: implementation -> build + `make test` -> commit ->
`/simplify` (recall-mode review, fixes committed) -> `/clean-and-refactor` (committed).
Test count grew 122 -> 139, all green; build green throughout.

- Phase 5 (foundation): renamed RmNotebook -> RmFolder + folder cache API; decided
  against unifying the five destination records (scales fine; localized refactor later
  if type count grows).
- Phase 0: a manual "Sync now" now writes a visible cycleSkipped event with the reason
  (no account, paused, no connected folders, rule disabled, folder empty, selection
  missing, all-tag-filtered); scheduled ticks stay quiet. Fixes the "spins then nothing"
  report.
- Phase 1: creating a Markdown destination requires choosing the folder and captures the
  default config; connections inherit it; multiple Markdown folders supported. Fixes
  "can't choose where .md files go".
- Phase 2: SyncRule.selectedFileIds scopes a rule to specific notebooks (no migration).
- Phase 3: NotebookScopePicker in the rule sheet — "sync only my journal" works.
- Phase 4: destination-first "Connect a folder" + actionable empty states; both flows
  converge on Ledger.connect.

Follow-ups deferred (not blocking): "already up to date" friendly message; event-log
decode resilience on downgrade; skip-event dedup; per-connection editing of OAuth
destinations from the destination detail (today via the rule sheet). Destination-record
unification remains intentionally unbuilt.
