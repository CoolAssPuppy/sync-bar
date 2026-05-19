# Architecture

SyncNerds is a SwiftUI menu bar app that orchestrates one-way syncs from reMarkable to Notion. The design mirrors mail-notifier and linear-bar in look, feel, and structural choices.

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
                   ├─ MenuBarPopover           (rule list, gear → main window)
                   ├─ MainView                  (sidebar + content + drawer)
                   │   ├─ Sidebar               (accounts, navigation, gear)
                   │   ├─ NotebookListView      (notebook rows + slide-up rule sheet)
                   │   ├─ RuleSheetView         (destination, title, OCR, output, db mapping)
                   │   ├─ SyncLogView           (event filter + clear log)
                   │   ├─ WorkspaceDetailView
                   │   ├─ RemarkableDetailView
                   │   └─ SettingsDrawer        (top-down panel, click-outside-to-dismiss)
                   │       └─ SettingsView      (General, OCR, Accounts, Notifications, Data, Advanced)
                   └─ WelcomeView                (3-step onboarding)

                 Services
                   ├─ SyncCoordinator           (timer + cycle orchestration, @MainActor)
                   ├─ RulesEngine               (pure logic, no I/O)
                   ├─ RemarkableClient          (protocol; MockRemarkableClient default)
                   ├─ NotionClient              (protocol; MockNotionClient default)
                   └─ KeychainStore             (KeychainAccess wrapper, iCloud-synced)

                 Models / state
                   ├─ Ledger.shared             (rules, events, accounts, notebooks)
                   ├─ AppSettings.shared        (interval, OCR provider, notifications…)
                   └─ ThemeStore.shared         (active palette + system observer)
```

## Single source of truth: SyncCoordinator

`SyncCoordinator` is a `@MainActor` `ObservableObject`. The `AppDelegate` owns one, injects it into the popover and the main window, and calls `start()` at launch. It exposes:

- `isSyncing`, `lastTickAt`, `nextTickAt`, `activeRuleId` — published so views show status pills, rotating menu bar icon, and "Last run …" labels.
- `syncNow(ruleId:)` — fires a one-off cycle (optionally targeted at a single rule). Called by menu items, the popover sync icon, and the rule sheet.
- `start()` / `stop()` — start and tear down the background timer.

The timer task awakens every `AppSettings.shared.syncIntervalSeconds`. Subscribers on `.syncIntervalChanged` and `.pauseSyncingChanged` rebuild the timer when settings shift.

## A sync cycle

```
SyncCoordinator.runCycle
├── (skip if no reMarkable account or paused)
├── For each enabled rule:
│    ├── ruleRunStarted event
│    ├── listPages(notebookId)
│    ├── For each page:
│    │    ├── RulesEngine.evaluate(rule, page, ocrText, previouslySyncedHash)
│    │    │     → .create(title) | .skip(reason)
│    │    └── On .create:  notion.createPage(workspaceId, destinationId, title)
│    │                      append pageSynced event
│    ├── On error: append pageFailed event, mark partial/error
│    └── ruleRunCompleted event + rule status updated in Ledger
└── Set lastTickAt, notify listeners
```

Mock clients return deterministic data, including the six sample notebooks (Q2 planning, Meeting notes, Daily journal, Book sketches, Customer research, Onboarding ideas). The first time a rule runs through the engine, every page produces a `.create` directive because no prior hash exists — the mock Notion client returns a synthetic page URL.

## Persistence

For v0.1 everything lives in `UserDefaults` behind the `Ledger` API:

- `Ledger.remarkableAccount` → `ledger.remarkableAccount`
- `Ledger.notionWorkspaces`  → `ledger.notionWorkspaces`
- `Ledger.rules`             → `ledger.rules`
- `Ledger.events`            → `ledger.events` (capped at 500)
- `Ledger.notebooks`         → `ledger.notebooks`

`AppSettings` writes individual primitive defaults under `settings.*` keys.

Tokens go through `KeychainStore` (synchronizable iCloud Keychain entries, service `com.strategicnerds.SyncNerdsApp`). The five typed keys cover OpenAI, Anthropic, reMarkable device, reMarkable user, and per-Notion-workspace tokens.

When CloudKit lands, the `Ledger` rewrites its internal storage with the same public methods. Views never touch persistence directly, so the swap is local.

## Theming

`ThemeStore.shared` publishes the active palette. The active palette is also injected into the SwiftUI environment via `\.theme` so views read `@Environment(\.theme) private var theme`. The store watches `NSApp.effectiveAppearance` and re-publishes when system light/dark flips while the user is on the `.system` theme.

Color tokens (background, surface, card, border*, foreground*, primary, success, warning, destructive, …) and spacing tokens live alongside the palette definitions in `ThemeStore.swift`. The 10 themes match mail-notifier exactly so the family looks consistent across apps.

## What deviates from the spec

The overnight spec asks for separate Swift packages, CloudKit private DB, real OAuth, Vision OCR, Sparkle release pipeline, and full XCTest plus snapshot/UI test coverage. To ship a working app in a single overnight window:

- The package boundaries (`RemarkableKit`, `NotionKit`, `OcrKit`, `RulesEngine`, `SyncCore`, `LedgerKit`, `KeychainKit`, `DesignSystem`) are implemented as folders under `Source/` with the same logical separation. They split into SPM packages without code changes once we set up a `Package.swift` workspace.
- CloudKit is replaced by UserDefaults-backed `Ledger`. The public API is shaped to match the eventual CloudKit version.
- Notion OAuth and reMarkable pairing are stubbed against `MockNotionClient` and `MockRemarkableClient`.
- OCR providers exist as enum choices in Settings but are not yet calling out to Vision / OpenAI / Anthropic.
- Sparkle entries are in `Info.plist` and we mirror mail-notifier's appcast hostname; the release script and signing setup land in v0.2.
- A single XCTest target (`SyncNerdsTests`) currently covers `RulesEngine` happy paths. Snapshot tests and UI tests are not present yet.

See `tasks/lessons.md` for any contradictions that came up while building.
