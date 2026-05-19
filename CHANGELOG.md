# Changelog

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
- 19 unit tests passing (was 14 at 0.1.0). New coverage:
  - `OCRPromptsTests` — mermaid extraction round-trip + prompt-sentinel guarantees.
  - `DestinationBindingTests` — Codable round-trip for each destination kind, aggregate-status rules.
  - `MarkdownDestinationClientTests` — end-to-end write with frontmatter and mermaid block.
  - `TitleTemplateTests` — every token substitutes, unknown tokens pass through.
  - `LedgerCascadeTests` — removeMarkdownTarget strips matching bindings; no-op `updateBindingRunResult` doesn't churn.

## 0.1.0 — 2026-05-19

Initial overnight build. Visual shell, mock-backed services, working sync cycle, theming, persistence, settings, onboarding.

(See `git log` for the initial commit if you need details — the 0.2.0 list above describes everything that's true today.)
