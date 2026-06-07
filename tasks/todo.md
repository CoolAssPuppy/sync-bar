# Notion -> Apple Notes backup sync

Branch: `notion-backup-source`. Notion is the Source of truth.
(Prior plan "source -> destination connection redesign v0.3" is complete; see git history.)

## Design (settled with user 2026-06-07)
- **Notion -> Apple Notes**, one-way. Notion always wins; a linked note is overwritten whenever its Notion `last_edited_time` changes (default, not strict mirror).
- **Apple Notes -> Notion** for orphans only (Apple notes with no Notion match), created once then linked. Gated behind user review (~17 orphans today).
- **Category** = a single-select Notion column named `Category` -> Apple Notes notebook (via `DestinationPayload.folderPath`).
- **Identity**: hidden `notion_id` marker stamped into every note SyncBar writes (self-healing after run 1); first-run match by notebook + title + (preserved) date seeds links.
- **Resume**: reuse `Ledger.recordSyncedPage` (versionHash = Notion `last_edited_time`, externalId = Apple note id). Adoption pre-seeds it.

## Steps (one commit each; `make build` + `make test` between; pkill app before tests)

- [x] **1. Notion read layer + block converter** (foundation, pure/testable)
  - `NotionSourceConfig` + `.notion` case in `SourceKind` / `SourceConfiguration` / `SourceRouter`
  - `NotionPageReader.swift`: query DB pages (paginated, optional `last_edited_time` filter), fetch page blocks; pure parse statics
  - `NotionBlockConverter.swift`: Notion block JSON -> `[NoteBlock]` (pure)
  - `NotionSourceClient.swift`: `SourceClient` conformer
  - Tests: page-summary parsing, block conversion
- [x] **2. Category -> notebook routing**
  - `AppleNotesDestinationClient` honors `DestinationPayload.folderPath` (notebook per Category) instead of only `config.folderName`
  - Coordinator passes per-item `folderPath`; tests
- [x] **3. first-run adoption** (marker abandoned — Apple Notes strips hidden HTML; identity lives in the ledger)
  - Apple Notes inventory reader (notebook + title + creation date + note id)
  - Pure matcher (notebook + normalized title + date) -> `Ledger.adoptExternalLink`; tests
- [ ] **4. Orphan upload (Apple -> Notion) with review gate**
  - Detect orphans (no marker, no match); build review list; create pages in Notion, then stamp + link; confirm-before-write UI gate
- [x] **5. UI wiring + adoption-on-first-run**
  - Notion selectable as a Source (workspace + database + folder-column picker) in the sync editor
  - Coordinator runs first-run adoption (link existing notes) before the first write; logs counts
  - Remaining polish: a pre-run review screen showing fresh/adopt/orphan counts (folds into step 4's gate)

- [ ] **4. Orphan upload (Apple -> Notion) with review gate** — DEFERRED, writes to Notion
  - Detect orphans (already returned by the matcher); build review list; create pages in Notion (Apple HTML -> blocks), then link; confirm-before-write UI gate

## Review
(filled in as steps complete)
