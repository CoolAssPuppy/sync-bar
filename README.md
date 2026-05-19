# SyncNerds

A macOS menu bar app that syncs your reMarkable handwritten notes into Notion. Lives next to MailNotifier and LinearBar in the Strategic Nerds menu bar family.

This is the v0.1 overnight build. The visual shell, sidebar navigation, menu bar popover, rules editor, sync log, and settings drawer are all in. reMarkable and Notion are wired against deterministic mocks so the UI is fully usable before the real device arrives. Real OAuth and CloudKit land in v0.2.

## What works today

- Menu bar status item with click-to-popover and right-click menu (Sync now, Open, Pause, Settings, Quit).
- Menu bar popover that mirrors Mail Notifier's chrome: brand header, configured rules with their last run time and result ("3 notes synced"), footer with sync-now, pause, open-window, gear, theme strip, quit.
- Main window with three regions (sidebar, notebook list, slide-up rules sheet) plus a sync log view.
- Settings drawer (gear icon → top-down panel with backdrop, escape-to-close) covering General, OCR, Accounts, Notifications, Data, Advanced.
- 10-theme palette (System, Hoth, Risa, Weasley, Starbuck, Cylon, Vader, Kirk, Hermione, Nerds) toggled live from the popover footer.
- Onboarding flow with welcome, reMarkable pairing (8-character one-time code), Notion connect, done state.
- Rules engine with title strategies (first line of OCR, template, page number, reMarkable date) and OCR mode (all, handwritten only, none).
- Sync coordinator runs a real cycle against mocked data, writes SyncedPage and SyncEvent records, posts a UserNotification on completion or failure (when enabled).
- Background timer fires at the configured interval (5/15/30/60/240 minutes, or manual only).
- Ledger persists to UserDefaults so accounts, rules, notebooks, and events survive relaunches. (CloudKit storage swaps in later — only `Ledger.swift` changes.)
- Keychain-backed OpenAI / Anthropic API key fields wired up via KeychainAccess.
- "Export ledger as JSON" save panel.

## What's deferred

- Real reMarkable cloud client (uses `MockRemarkableClient`).
- Real Notion OAuth (uses `MockNotionClient`).
- Real OCR via Vision / OpenAI / Anthropic (the chooser writes the setting; calls are stubbed).
- CloudKit private database (the `Ledger` API matches but is UserDefaults-backed).
- Sparkle release pipeline (Info.plist entries exist; signing keys and appcast URL aren't yet wired up).
- App-specific icon set (using SF Symbols for now; design assets land later).

The five protocols (`RemarkableClient`, `NotionClient`, `OcrProvider`, `LedgerService`-style ops on `Ledger`, `KeychainStore`) are designed so each real implementation drops in without touching the views.

## Prerequisites

- macOS 14.0 (Sonoma) or later.
- Xcode 15+ command-line tools (`xcode-select --install`).
- Homebrew packages: `brew install xcodegen`.

You do not need to open Xcode to build, run, or test.

## Day-of-pairing instructions

When the reMarkable arrives:

1. Sign in at <https://my.remarkable.com>.
2. Open Connect → generate an 8-character one-time pairing code.
3. Open SyncNerds → click the reMarkable row in the sidebar (or the Pair button on the notebook empty state).
4. Paste the code, hit *Pair device*. Notebooks load from your reMarkable cloud library.
5. Click a notebook → pick a Notion destination → save. The first sync runs on the next timer tick.

Until then, the mock client returns six sample notebooks ("Q2 planning", "Meeting notes", etc.) so you can exercise every screen.

## Build, run, test

```
make bootstrap   # one-time: generates SyncNerds.xcodeproj and resolves deps
make build       # debug build → build/Build/Products/Debug/SyncNerds.app
make run         # build + launch
make release     # release build (no signing yet)
make test        # unit tests
make clean       # nuke build/ and the generated xcodeproj
```

The first launch creates the welcome screen because no accounts exist. Subsequent launches stay in the menu bar; click the icon to bring the popover up, or use ⌘, while the main window is open to slide the settings drawer down from the top.

## Project layout

Mirrors mail-notifier's flat, XcodeGen-driven layout.

```
sync-bar/
  Source/
    App/              Entry point and AppDelegate
    Models/           Domain types, ThemeStore, AppSettings, Ledger
    Services/         RemarkableClient, NotionClient, RulesEngine, SyncCoordinator, KeychainStore
    Utilities/        Formatters, Logger, Notification names
    Views/            All SwiftUI views (MainView, Sidebar, MenuBarPopover, SettingsDrawer, …)
      Components/     Reusable AppCard, AppPrimaryButton, ThemeStrip, StatusPill, BrandMark, …
  Tests/              XCTest suite (currently RulesEngine)
  Images.xcassets/    Asset catalogue (AppIcon placeholder for now)
  scripts/            build.sh, run.sh, test.sh, bootstrap.sh
  Info.plist
  SyncNerds.entitlements
  project.yml         XcodeGen spec
  Makefile
```

## Architecture summary

Everything routes through one `@MainActor` `SyncCoordinator` that owns the timer and orchestrates each cycle. Views observe a single `Ledger` for all persistent state. Service protocols (`RemarkableClient`, `NotionClient`) let the rest of the app stay client-agnostic; mock implementations ship by default. Theme tokens come from `ThemeStore.shared` and route into views via the `\.theme` environment key.

See `ARCHITECTURE.md` for a full diagram and the data flow per sync cycle.

## License

Copyright 2026 Strategic Nerds.
