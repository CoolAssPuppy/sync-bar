# SyncNerds

A macOS menu bar app that turns your reMarkable handwritten notes into clean text and pushes them to wherever you want them: Notion, Linear, Google Docs, Apple Notes, or a folder of Markdown files. Lives next to MailNotifier and LinearBar in the Strategic Nerds menu bar family.

This is the v0.2 build. The visual shell, sidebar navigation, menu bar popover with per-rule sync status, multi-destination rules sheet, settings drawer, on-device OCR (Apple Vision), HTTP clients for OpenAI and Anthropic vision endpoints, real Notion API writes when a workspace token is configured, real Markdown and Apple Notes writes, and Sparkle-based auto-updates are all in. CloudKit storage scaffolding is in place; the in-memory + UserDefaults ledger is the default until your reMarkable device arrives and we cut a release.

## What works today

### Menu bar shell
- Status item with a clockwise GPU-driven spin while syncing, click for the popover, right-click for Sync now / Open / Pause / Settings / Check for updates / Quit.
- Popover mirrors Mail Notifier's chrome: brand header, configured rules with the number of destinations attached, aggregate "Last run, N notes synced" line, per-binding mini-rows you can sync individually, footer with sync-all / pause / open-window / gear / theme strip / quit.

### Main window
- Sidebar with the source (reMarkable) on top, all your destination accounts grouped by kind below, an "Add destination" button, and View entries for the Notebook list and Sync log.
- Notebook list with status pills showing how many destinations are attached and what the last aggregate run looked like.
- Slide-up rule sheet under the notebook list: pick a title strategy, OCR mode, attach as many destinations as you want, edit each binding inline.
- Right-pane detail views for every connected account: Notion workspace, Linear team, Google account, Markdown folder, Apple Notes folder, reMarkable device.
- Settings drawer (gear icon at the bottom of the sidebar or ⌘,) with six cards: General, OCR, Accounts, Notifications, Updates, Data, Advanced.

### Destinations (one reMarkable notebook → 0..N destinations)
- **Notion** — page or database. Real API writes when a workspace token is in Keychain; mock otherwise.
- **Linear** — issues per page. Real GraphQL writes when a personal access token is in Keychain.
- **Google Docs** — one doc per page or append to a single doc; needs an OAuth access token in Keychain for real writes.
- **Apple Notes** — creates the named folder if it doesn't exist and writes one note per page via AppleScript. No accounts or tokens required.
- **Markdown files** — one .md file per page with optional YAML frontmatter and a code-fenced mermaid block when the OCR pass detects a diagram. No accounts required.

Adding a destination type later means: one enum case, one configuration struct, one client, one detail view, one form. The architecture documents this in `Source/Models/Destinations.swift`.

### OCR
- **Apple Vision** (default, on-device, no network).
- **OpenAI** — chat-completions vision endpoint with the prompt in `Source/Services/OCRPrompts.swift`.
- **Anthropic** — messages API with image content, same prompt.
- LLM providers emit a `<mermaid>…</mermaid>` block when a page is a diagram with no prose; the rules engine splits it out and the Markdown destination writes it inside a fenced mermaid code block (Obsidian, Bear, iA Writer all render it).

Tweak the prompt in one place: `OCRPrompts.systemPrompt`.

### Engine + scheduling
- `SyncCoordinator` runs cycles on a user-configurable timer (5/15/30/60/240 minutes or manual only). Bindings within a rule sync in parallel up to 3-way concurrency. OCR runs once per page and the result fans out to every destination on that rule.
- `RulesEngine` decides per page: create, skip-unchanged, skip-empty-and-ocr-disabled.
- All writes go through one `Ledger`. Mutations are equality-gated so no-op updates don't churn SwiftUI. Persistence is debounced at 250ms to avoid re-encoding the events array on every appended event.
- Sync log captures every rule start, page sync, page failure, and rule completion.

### Distribution
- Sparkle 2.6+ wired up; `SUFeedURL` and `SUPublicEDKey` set in `Info.plist`. Settings → Updates surfaces the installed version and a "Check now" button.
- Launch-at-login via SMAppService (macOS 13+).
- KeychainAccess stores all secrets in iCloud Keychain (synchronizable across the user's Macs).

## What's deferred to v0.3

- A real reMarkable cloud client that walks the sync/v3 index graph (the protocol is reverse-engineered, not officially documented; there are no webhooks, only polling).
- Notion / Linear / Google OAuth flows (today you paste tokens manually in Settings).
- Real CloudKit reads/writes from `Ledger` (scaffolding is in `CloudKitLedger.swift` with the right entitlement; the active store is still UserDefaults until we can sign + entitle a build for real CloudKit testing).
- App icon set (Images.xcassets/AppIcon.appiconset has the Contents.json but no PNGs yet).
- Signed and notarized DMG release pipeline (scripts/release.sh is a stub).
- Snapshot and UI tests.

## Prerequisites

- macOS 14.0 (Sonoma) or later.
- Xcode 15+ command-line tools (`xcode-select --install`).
- Homebrew packages: `brew install xcodegen swiftlint`.

You do not need to open Xcode to build, run, or test.

## Day-of-pairing instructions

When the reMarkable arrives:

1. Sign in at https://my.remarkable.com.
2. Open Connect, generate an 8-character one-time pairing code.
3. Open SyncNerds, click the reMarkable row in the sidebar.
4. Paste the code, hit *Pair device*.
5. Notebooks load from your reMarkable cloud library.
6. Click a notebook, hit "Add Notion" (or any of the other four), pick a destination, save. The first sync runs on the next timer tick.

Until then, the mock client returns six sample notebooks ("Q2 planning", "Meeting notes", etc.) so you can exercise every screen.

## Build, run, test

```
make bootstrap   # one-time: generates SyncNerds.xcodeproj and resolves deps
make build       # debug build → build/Build/Products/Debug/SyncNerds.app
make run         # build + launch
make release     # release build (no signing pipeline yet)
make test        # unit tests (19 passing today)
make lint        # SwiftLint with the config under .swiftlint.yml
make clean       # nuke build/ and the generated xcodeproj
```

The first launch creates the welcome screen because no accounts exist. Subsequent launches stay in the menu bar; click the icon to bring the popover up, or use ⌘, while the main window is open to slide the settings drawer down from the top.

## Project layout

```
sync-bar/
  Source/
    App/                          Entry point and AppDelegate
    Models/                       Domain, Ledger, AppSettings, ThemeStore, Destinations
    Services/
      Destinations/               One client per destination kind
      OcrProvider.swift           VisionOcrProvider + real OpenAI + Anthropic
      OCRPrompts.swift            One-file place to tweak the OCR prompt
      RemarkableClient.swift      Mock + real client + factory
      RealNotionClient.swift      Notion v2022-06-28 calls (catalog, schema, write)
      RulesEngine.swift           Pure-logic title + skip decisions
      SyncCoordinator.swift       Timer + cycle orchestration with TaskGroup
      KeychainStore.swift         All secrets, iCloud-synced
      UpdaterManager.swift        Sparkle wrapper
      LaunchAtLoginManager.swift  SMAppService bridge
      CloudKitLedger.swift        v0.3-pending CloudKit scaffolding
      DestinationClient.swift     Protocol + router + DestinationError
      TitleTemplate.swift         Centralized {notebook} {page_n} {date} {title} tokens
      HTTP.swift                  Shared status validation + JSON helpers
    Utilities/                    Formatters, Logger, Notification names
    Views/                        All SwiftUI views
      Components/                 Reusable AppCard, AppPrimaryButton, ThemeStrip, StatusPill, BrandMark
  Tests/                          XCTest suite (RulesEngine, OCR prompts, Markdown writer, Title template, Destination bindings, Ledger cascade)
  Images.xcassets/                Asset catalogue (AppIcon placeholder)
  scripts/                        build.sh, run.sh, test.sh, bootstrap.sh, lint.sh
  Info.plist
  SyncNerds.entitlements
  project.yml                     XcodeGen spec
  Makefile
  .swiftlint.yml
```

## Architecture summary

Everything routes through one `@MainActor SyncCoordinator` that owns the timer and orchestrates each cycle. Views observe a single `Ledger` for all persistent state. Service protocols (`RemarkableClient`, `NotionClient`, `DestinationClient`, `OcrProvider`) let the rest of the app stay client-agnostic; mock implementations ship by default. Theme tokens come from `ThemeStore.shared` and route into views via the `\.theme` environment key.

See `ARCHITECTURE.md` for the full diagram and the data flow per sync cycle.

## License

Copyright 2026 Strategic Nerds.
