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
- [ ] 0. Coordinator writes a visible event at every silent early-return (no enabled
      rules with destinations, no files, tag filter excluded all, paused, no account).
      Add `SyncEventType.cycleSkipped` with a human reason. Tests: each empty-work
      condition yields exactly one skip event. (Addresses #2's invisibility.)

### Phase 1 — destinations carry a default config
- [ ] 1. Markdown destination creation captures the folder (NSOpenPanel up front) +
      filename template + frontmatter as the destination default; cannot finish
      without a folder. `MarkdownTarget` holds the full config.
- [ ] 2. Connection-creation (rule-sheet quick-add AND binding editor) inherits the
      destination default instead of empty. Remove the empty-path quick-add path.
      Tests: connecting a folder yields a binding with the chosen folder. (Fixes #1.)
- [ ] 3. Default-config capture for the other types (Notion default db/page, Linear
      default team/project, Google default folder, Apple Notes folder). One destination
      type per sub-step if it grows large.

### Phase 2 — source scope in data + engine
- [ ] 4. Introduce `SourceScope` + backward-compatible `SyncRule` decoding; migrate
      reads/writes (`rule(forNotebookId:)`, `pruneRules`, idempotency keys).
- [ ] 5. Coordinator resolves `SourceScope` -> files (folder: `listFiles`; notebooks:
      fetch by id). Tests: notebook-scoped rule syncs only those docs; folder-scoped
      syncs all + future. (Fixes #3 at the engine level.)

### Phase 3 — source tree UI
- [ ] 6. Notebook list renders folders that expand to their `RmFile` documents.
- [ ] 7. Connection creation lets you pick a folder or check specific notebooks ->
      builds a `SourceScope`. (Completes "sync only my Journal".)

### Phase 4 — both-as-peers + guided empty states
- [ ] 8. Destination-first: destination detail shows "connect a source" empty state ->
      source picker -> creates/extends a connection (find-or-create rule by source scope).
- [ ] 9. Guided empty states at each level: no reMarkable, no destinations, destination
      with no connections, source with nothing routed. Each points to the next action.

### Phase 5 — deferred cleanup (separate ADR, do NOT block fixes on this)
- [ ] 10. Unify the five destination arrays into one `Destination` type.
- [ ] 11. Rename `RmNotebook` -> `RmFolder` throughout (removes the naming confusion
      that made per-notebook sync look like it should already exist).

## Notes / risks

- `SyncRule` is Codable-from-UserDefaults; changing its key field breaks decoding of
  existing data unless the decoder reads the legacy `rmNotebookId` fallback. This is
  the highest-risk change; cover it with a decode-old-write-new test.
- Destination-first connection creation needs `SourceScope` equality to find-or-create
  the right rule, and sensible defaults for the rule-level note settings (OCR/title).
- Phase 0 and 1 deliver user-visible fixes immediately and are independent of 2–4.
- Keep strict-concurrency clean; trust `xcodebuild`/`make test` over SourceKit.

## Review

(to be filled in as commits land)
