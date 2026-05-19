# Architecture

SyncNerds is a SwiftUI menu bar app that orchestrates one-way syncs from a reMarkable tablet to five user-facing destination kinds. The design mirrors mail-notifier and linear-bar in look, feel, and structural choices.

## Overview

```
                 ┌─────────────────────────────────────────────────────┐
                 │                AppKit shell                         │
                 │                                                     │
   AppDelegate ──┼─►  NSStatusItem (variableLength, template SF icon)  │
                 │       │                                             │
                 │       └─► NSPopover ── NSHostingController ── MenuBarPopover (SwiftUI)
                 │                                                     │
   AppDelegate ──┼─►  NSWindow (1040x680, dark chrome) ──► MainView (SwiftUI)
                 └─────────────────────────────────────────────────────┘

   SwiftUI view layer
   ├─ MenuBarPopover           (per-rule cards + per-binding mini rows, gear opens main window)
   ├─ MainView                 (sidebar + content + drawer)
   │   ├─ Sidebar              (source row, destination accounts grouped by kind, View nav, gear)
   │   ├─ NotebookListView     (notebook rows with status pills + slide-up rule sheet)
   │   ├─ RuleSheetView        (rule-level defaults + N destination bindings + Add buttons)
   │   ├─ BindingEditorSheet   (per-kind form: Notion / Linear / Google / Apple Notes / Markdown)
   │   ├─ AddDestinationSheet  (account creation: pick a kind + minimal setup)
   │   ├─ SyncLogView          (event filter + clear log)
   │   ├─ NotionWorkspaceDetailView / LinearAccountDetailView /
   │     GoogleAccountDetailView / MarkdownTargetDetailView /
   │     AppleNotesTargetDetailView / RemarkableDetailView
   │   └─ SettingsDrawer       (top-down panel: General / OCR / Accounts /
   │                            Notifications / Updates / Data / Advanced)
   └─ WelcomeView              (3-step onboarding)

   Services
   ├─ SyncCoordinator          (timer + TaskGroup-based cycle orchestration)
   ├─ RulesEngine              (pure logic, no I/O)
   ├─ DestinationRouter        (kind → DestinationClient)
   ├─ DestinationClient impls  (Notion, Linear, Google Docs, Apple Notes, Markdown)
   ├─ RemarkableClient impls   (Mock + Real cloud client)
   ├─ NotionClient impls       (Mock + RealNotionClient for catalog/schema/write)
   ├─ OcrProvider impls        (Vision on-device, OpenAI vision, Anthropic vision)
   ├─ OCRPrompts               (one place to tweak the LLM instructions)
   ├─ KeychainStore            (KeychainAccess wrapper, iCloud-synced)
   ├─ HTTP                     (shared status validation, JSON helpers)
   ├─ TitleTemplate            ({notebook} {page_n} {date} {title} resolver)
   ├─ UpdaterManager           (Sparkle wrapper)
   ├─ LaunchAtLoginManager     (SMAppService bridge)
   └─ CloudKitLedger           (v0.3-pending CloudKit scaffolding)

   Models / state
   ├─ Ledger.shared            (rules, events, accounts of all kinds, notebooks)
   ├─ AppSettings.shared       (interval, OCR provider, notifications, pause, …)
   └─ ThemeStore.shared        (active palette + system observer)
```

## Single source of truth: SyncCoordinator

`SyncCoordinator` is a `@MainActor ObservableObject`. The `AppDelegate` owns one, injects it into the popover and the main window, and calls `start()` at launch. It exposes:

- `isSyncing`, `lastTickAt`, `nextTickAt`, `activeRuleId`, `activeBindingId` — published so views show status pills, a rotating menu bar icon, and per-binding "Last run …" labels.
- `syncNow(ruleId:bindingId:)` — fires a one-off cycle (optionally targeted at a single rule or even a single binding).
- `start()` / `stop()` — start and tear down the background timer.

The timer task awakens every `AppSettings.shared.syncIntervalSeconds`. Subscribers on `.syncIntervalChanged` and `.pauseSyncingChanged` rebuild the timer when settings shift.

## A sync cycle

```
SyncCoordinator.runCycle
└─ For each enabled rule with at least one destination:
   ├─ remarkable.listPages(notebookId)
   ├─ OCR once per page (single transcribe, result fanned out to every binding)
   ├─ Run bindings in parallel (TaskGroup, max 3 concurrent):
   │  ├─ For each page:
   │  │  ├─ RulesEngine.evaluate(rule, page, ocrText, previouslySyncedHash)
   │  │  │     → .create(title) | .skip(.unchanged | .ocrSkippedAndPageEmpty | .ruleDisabled)
   │  │  └─ On .create: DestinationRouter.client(for: kind).write(payload, configuration)
   │  │                  → DestinationWriteResult (id, URL, notes)
   │  ├─ Ledger.appendEvent for each page outcome (debounced persistence)
   │  └─ Ledger.updateBindingRunResult (equality-gated)
   └─ Optional UserNotification on failure/success per AppSettings
```

OCR fan-out means a 5-destination rule does one transcription per page instead of five. The TaskGroup means three destinations sync at once (capped because Apple Notes' AppleScript pathway is contention-sensitive).

## Multi-destination model

```
SyncRule
├─ id
├─ rmNotebookId, rmNotebookName
├─ titleStrategy + titleTemplate (rule-level defaults)
├─ ocrMode (rule-level default)
├─ destinations: [DestinationBinding]
│   ├─ id, enabled, createdAt
│   ├─ configuration: DestinationConfiguration (sum type, one case per kind)
│   ├─ lastRunAt, lastRunStatus, lastRunPagesSynced, lastRunError
│   └─ ocrModeOverride, titleStrategyOverride (optional per-binding)
└─ aggregateLastRunAt / aggregateLastRunPagesSynced / aggregateLastRunStatus
   (computed properties; the menu bar popover shows these)
```

Adding a destination type later is mechanical:
1. Add a case to `DestinationKind`.
2. Add a `*DestinationConfig` struct + a case to `DestinationConfiguration`.
3. Implement `DestinationClient` for it.
4. Add a form view in `BindingEditorSheet`.
5. Add a detail view + a sidebar row.

## Persistence

For v0.2 everything lives in `UserDefaults` behind the `Ledger` API:

- `Ledger.remarkableAccount` → `ledger.remarkableAccount`
- `Ledger.notionWorkspaces` / `linearAccounts` / `googleAccounts` / `markdownTargets` / `appleNotesTargets`
- `Ledger.rules` (includes all destination bindings)
- `Ledger.events` (capped at 500, debounced persistence)
- `Ledger.notebooks`

`AppSettings` writes individual primitive defaults under `settings.*` keys.

Tokens go through `KeychainStore` (synchronizable iCloud Keychain entries, service `com.strategicnerds.SyncNerdsApp`). Typed keys cover OpenAI, Anthropic, reMarkable device + user, per-Notion-workspace, Linear, and per-Google-account tokens.

When CloudKit lands, the active `Ledger` rewrites its internal storage with the same public methods. Views never touch persistence directly so the swap is local.

## Theming

`ThemeStore.shared` publishes the active palette. The active palette is also injected into the SwiftUI environment via `\.theme` so views read `@Environment(\.theme) private var theme`. The store watches `NSApp.effectiveAppearance` and re-publishes when system light/dark flips while the user is on the `.system` theme.

Color tokens (background, surface, card, border*, foreground*, primary, success, warning, destructive, …) and spacing tokens live alongside the palette definitions in `ThemeStore.swift`. The 10 themes (System, Hoth, Risa, Weasley, Starbuck, Cylon, Vader, Kirk, Hermione, Nerds) match mail-notifier exactly so the family looks consistent.

## Error handling

- `DestinationError` covers destination-domain failures (wrong configuration, script failed, API failed, rate limited, file system, network).
- `OcrError` covers OCR-only failures.
- `NotionError`, `RemarkableError` cover service-specific cases.
- Views never show raw `\(error)`; they route through `Formatters.userMessage(for:)` which prefers `LocalizedError.errorDescription` and falls back to `NSError.localizedDescription`.

## Known tech debt (tracked separately)

The full audit lives in `tasks/lessons.md`. Highlights for v0.3:

- Views still reach `Ledger.shared` / `KeychainStore.shared` directly; migrating to `@Environment` injection across the view tree is still pending. `SyncCoordinator` is already DI-ready (ledger, settings, keychain, remarkable, engine all injectable).
- `scripts/release.sh` is a stub; no notarization / DMG pipeline yet (Sparkle keys + feed URL are in Info.plist).
- `BindingEditorSheet` is still 700+ lines — split per-kind forms into their own files.
- Real reMarkable cloud client (sync/v3 index walker) and Notion / Linear / Google OAuth flows remain to be wired.
- Real CloudKit reads/writes pending signed-build provisioning. Scaffolding ready in `CloudKitLedger.swift`.
