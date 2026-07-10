# Changelog

## Unreleased

### Added
- X threads: bookmarked or liked tweets now sync with the author's own
  thread (self-replies only, never other people's replies), separated by a
  `~~~` rule between tweets. Mid-thread bookmarks fetch the conversation
  root too. Threads older than 7 days sync root-only (X's recent-search
  window); threads cap at 100 self-replies; the thread is captured at sync
  time and already-synced tweets are not re-expanded. Thread reads bill
  against the same 650/month budget as the crawl. Own posts are excluded —
  each thread tweet already syncs as its own item.
- Notion mapping: a new "Full text (tweet + thread)" field (`{text}` token)
  carries the complete synced text into any rich_text column, e.g. a Notes
  column the user adds themselves.
- X content quality: t.co shorteners are resolved to their real URLs in the
  synced text, and attached photos (or video preview frames) are embedded —
  natively in Notion, as links in Apple Notes and Google Docs.

### Fixed
- Notion: rich_text property values past Notion's 2000-character
  per-object cap are now chunked instead of failing the row write.

## 1.5.1 — 2026-07-01

### Fixed
- Notion → Markdown: a note whose title contains a `/` no longer spawns a stray
  subfolder on sync. The template is now split into path components *before*
  tokens are substituted, so a `/` arriving through a value (e.g. a note titled
  `Jess/Prashant 1-1`) is sanitized into the file name instead of creating a
  directory.

## 1.4.0 — 2026-06-29

- Sync Twitter Bookmarks, Likes, and Posts to destinations of your choice.
- Free for a limited time (Elon started charging for the API, F Elon).
- Twitter will become a paid sync by the end of July.

### Added
- **Twitter as a source** (shown with the Twitter bird; internally the `X` source). Connect once and choose Bookmarks, Likes, or Posts per sync.
- **Twitter → Notion database column mapping.** The mapping is source-aware: Twitter fields (tweet text, author handle/name, tweet URL, date, id) map to your database's columns, with smart defaults (URL, Author, Site, Source, Tags, Saved, Status). The schema panel surfaces load errors instead of spinning forever.
- All UI text is now selectable and copyable, including error messages.
- **X (Twitter) as a source.** Connect an X account with OAuth 2.0 + PKCE and
  sync three independent content streams — Bookmarks, Likes, and your own Posts —
  into any destination. Only the scopes the chosen streams need are requested,
  and refresh tokens are stored in the Keychain.
  - Each stream is its own sync with its own state: newest-synced id (incremental
    cursor), a durable processed-id set (dedup by content id, since bookmarks
    expose no timestamp or `since_id`), and last-attempted/last-successful times
    (`XSyncStateStore`). Initial sync crawls the full history; later runs fetch
    newest-first and stop the moment they hit an already-synced item.
  - Every tweet is normalized into a neutral content object (`XContent`) and
    carried through the existing `SourceItem` / `NoteContent` seam, so all
    destinations (Markdown, Notion, …) consume it unchanged.
  - New: `XAPIClient`, `XAuthService` / `XTokens`, `XSourceClient`,
    `XSyncStateStore`, `XAccount`, `XStream`, `XSourceConfig`. New secrets
    `X_CLIENT_ID` / `X_CLIENT_SECRET`.

## 0.3.0-dev — 2026-05-20 (overnight)

UI polish, real branding, audit-driven cleanup. Visible additions:

### Added
- App icon set (charcoal squircle + yellow interlocked-arrows mark) and a matching menu bar template image. The menu bar swaps to the yellow variant while syncing.
- `scripts/generate-icons.py` renders every asset from one drawing routine.
- Destination header gear → inline drawer with Rename / Reauthorize / Delete; rename helpers per kind on `Ledger`, including a cascade for Apple Notes folder renames.
- Rule slider redesign: single "Add destination" picker when empty, a binding dropdown plus inline panel when populated. The big yellow + button now opens a kind menu (no longer hardcoded to Notion).
- Notion column-mapping UI now writes its values into Notion: every `NotionPropertyMapping` case is translated to the v2022-06-28 properties payload.
- LoadState&lt;T&gt; for the Notion catalog + schema fetch so 401 / 429 / network failures show up in the binding editor instead of presenting an empty picker.
- `NotionClientFactory` picks the real Notion client when a workspace token is in Keychain.
- Per-binding `titleStrategyOverride` and `ocrModeOverride` are now actually honored by `SyncCoordinator`.
- Settings → OCR Save buttons compress to a 22×22 inline checkmark; Sync all / Refresh in the notebook header are icon-only.
- Sync log drawer hosts Export ledger and Clear log in its footer; sync events now record OCR failures so the audit trail is complete.

### Changed
- `SyncCoordinator` now takes `AppSettings` and `KeychainStore` as init dependencies (alongside `Ledger`, `RemarkableClient`, `RulesEngine`).
- Timer re-reads `syncIntervalSeconds` on each loop so settings changes apply on the next tick.
- Don't ship empty bytes to LLM OCR providers; synthesize `[blank page]` results until the real reMarkable rasteriser lands.
- Notify-on-success notifications no longer fire on zero-result cycles.
- Markdown / Apple Notes removal no longer cascades bindings owned by sibling targets that share the same path / folder name.
- `Ledger.upsert` uses Equatable directly instead of JSON-encoding both sides.

### Removed
- `connectMockWorkspace` from the `NotionClient` protocol (mock-only concept that the real client threw for).
- Dead `NavRow`, `currentRule`, `showAddKindPicker`, `persistWorkspaces`, `areEqualEncoded`.

### Docs
- README + ARCHITECTURE refreshed to match the v0.3-dev surface; test count corrected to 24.

## 0.2.0 — 2026-05-19 (late)

Multi-destination architecture and real services. Same overnight session as 0.1.0; bumped for the scope of the rewrite.

### Added
- Multi-destination model: one reMarkable notebook → 0..N `DestinationBinding`s.
- Five destination kinds, each with a real client implementation:
  - Notion (real API writes when a workspace token is in Keychain; mock otherwise).
  - Linear (real GraphQL writes when a personal access token is in Keychain).
  - Google Docs (real Drive + Docs API writes when an OAuth access token is in Keychain).
  - Apple Notes (creates the folder if needed, writes via AppleScript through `Task.detached`).
  - Markdown files (one .md per page, optional YAML frontmatter, mermaid block when detected).
- `OCRPrompts` — single tweak point for the LLM transcription instructions, including the `<mermaid>…</mermaid>` sentinel that triggers diagram extraction.
- Real OCR providers: `VisionOcrProvider` (on-device), `OpenAIOcrProvider` (chat completions vision), `AnthropicOcrProvider` (messages API).
- `RealNotionClient` for catalog search + database schema retrieval + page creation.
- `RealRemarkableClient` scaffolding for the documented pair / refresh-user-token endpoints.
- `CloudKitLedger` scaffolding with the right iCloud entitlement.
- Sparkle integration (`UpdaterManager`, "Check for updates…" in the right-click menu and Settings → Updates card).
- Launch-at-login via `SMAppService.mainApp` (`LaunchAtLoginManager`).
- New right-pane detail views for Linear, Google, Markdown, Apple Notes accounts.
- `AddDestinationSheet` modal lets users pick a kind and run minimal setup.
- `BindingEditorSheet` modal hosts per-kind binding forms.
- Shared `HTTP` helper with status validation; Linear/Google clients now report 401/403/429 properly instead of swallowing them.
- `DestinationError` enum replaces `OcrError.providerRefused` in destination domain code.
- `TitleTemplate` centralizes `{notebook}`, `{page_n}`, `{date}`, `{title}` token resolution; previously hand-rolled in four places.
- `Formatters.userMessage(for:)` for user-facing error strings.
- SwiftLint configuration ported from linear-bar.

### Changed
- `SyncCoordinator.runRule` now OCRs once per page (not per page × binding) and runs bindings in a 3-way `TaskGroup`.
- `Ledger.persistRules` and `Ledger.persistEvents` are debounced at 250ms so a 50-page sync no longer JSON-encodes the events array on every appended event.
- Ledger setters are equality-gated; no-op writes don't post notifications.
- Status-bar spin replaced by a single `CABasicAnimation` (was a 30fps async-sleep loop).
- Nine per-collection upsert/remove pairs in `Ledger` collapsed to one generic pair; removal cascades into rule bindings for all five destination kinds (previously Markdown and Apple Notes did not cascade).
- `AppSettings` is now `@MainActor` and Swift-6-strict-concurrency-clean.
- `KeychainStore` declared `@unchecked Sendable`.

### Removed
- `RemarkableClient.downloadNotebookPdf` and both implementations; unused.
- `RemarkableClientFactory`, `NotionClientFactory`; views construct mocks directly so factories were dead.
- `selectedRuleId` plumbing in `NotebookListView` and `MainView`; set but never read.
- `statusMessage` state in `AddDestinationSheet`; set only to nil.
- A pile of "for now" / "v0.1" / "overnight build" comments.

### Tests
- 24 unit tests passing (was 14 at 0.1.0). New coverage:
  - `OCRPromptsTests` — mermaid extraction round-trip + prompt-sentinel guarantees.
  - `DestinationBindingTests` — Codable round-trip for each destination kind, aggregate-status rules.
  - `MarkdownDestinationClientTests` — end-to-end write with frontmatter and mermaid block.
  - `TitleTemplateTests` — every token substitutes, unknown tokens pass through.
  - `LedgerCascadeTests` — removeMarkdownTarget strips matching bindings; no-op `updateBindingRunResult` doesn't churn.

## 0.1.0 — 2026-05-19

Initial overnight build. Visual shell, mock-backed services, working sync cycle, theming, persistence, settings, onboarding.

(See `git log` for the initial commit if you need details — the 0.2.0 list above describes everything that's true today.)
