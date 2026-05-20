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
- **Notion** — page or database. Connect with OAuth; real API writes once connected, mock otherwise.
- **Linear** — issues per page. Connect with OAuth; real GraphQL writes once connected, mock otherwise.
- **Google Docs** — one doc per page or append to a single doc. OAuth setup is documented; the client is still mock.
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

## New in this release (v0.2)

- Notion and Linear OAuth connect flows, replacing manually pasted tokens. See [OAuth and developer app setup](#oauth-and-developer-app-setup).
- A real reMarkable cloud client that walks the sync index graph and rasterizes pages for OCR. The protocol is reverse-engineered (no webhooks, polling only) and the v6 stroke rendering needs validation against a physical device.
- Real destination brand logos and the Apple Notes automation entitlement.

## Deferred to a later release

- Google Docs OAuth (the developer-app setup is documented; the client stays mock for now).
- Real CloudKit reads/writes from `Ledger` (scaffolding is in `CloudKitLedger.swift` with the right entitlement; the active store is still UserDefaults until we can sign + entitle a build for real CloudKit testing).
- Snapshot and UI tests.

The signed, notarized DMG release pipeline is wired (`scripts/release.sh`); see `scripts/SPARKLE.md` for the one-time prerequisites.

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
make test        # unit tests (31 passing today)
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

## OAuth and developer app setup

Notion and Linear connect through OAuth (Google's setup is documented here too,
but its client is still mock). Each needs a developer app you register once,
plus client credentials stored in the Doppler `sync-bar` project and baked into
the build. reMarkable uses an eight-character device code and needs no developer
app. Apple Notes and Markdown are local and need nothing.

### How credentials flow

1. Create the developer apps below and copy each client id and secret.
2. Create a Doppler project named `sync-bar` (config `dev`) and add the keys
   listed under "Doppler keys" below.
3. Run `./scripts/pull-secrets.sh` to write them into `Secrets.xcconfig`
   (gitignored). The build bakes them into the app's Info.plist; `AuthSecrets`
   reads them at runtime and also honors a `doppler run` environment override.
4. Rebuild. A provider whose credentials are missing shows a disabled connect
   button rather than starting a flow that can't finish.

The redirect URIs below are exact. Register them verbatim.

### Notion

1. Go to https://www.notion.so/my-integrations and create a new integration of
   type **Public**.
2. Under **OAuth Domain & URIs**, add the redirect URI:
   `http://localhost:53117/oauth/notion`
   (Notion rejects custom URL schemes, so SyncNerds captures the redirect on a
   loopback HTTP listener at this fixed port.)
3. Set the capabilities you want to grant (reading content is enough to
   transcribe; add insert/update content to let SyncNerds create pages).
4. Copy the **OAuth client ID** and **OAuth client secret**.

### Linear

1. Go to https://linear.app/settings/api/applications/new and create an OAuth
   application.
2. Set the redirect/callback URL to: `syncnerds://oauth/linear`
   (Linear allows custom URL schemes, so this uses the in-app web session.)
3. Requested scopes are `read,write` (write is needed to create issues).
4. Copy the **Client ID** and **Client secret**.

### Google (documented; client still mock)

1. In the Google Cloud console, create an OAuth client of type **Desktop app**
   (desktop clients use a loopback redirect; no custom scheme).
2. Enable the **Google Docs API** and **Google Drive API**.
3. Scopes when the client lands: `https://www.googleapis.com/auth/documents` and
   `https://www.googleapis.com/auth/drive.file`.
4. Copy the **Client ID** and **Client secret**.

### reMarkable

No developer app. Sign in at https://my.remarkable.com, open **Connect**, and
generate an eight-character one-time code. Paste it into SyncNerds (sidebar
reMarkable row, or onboarding). SyncNerds exchanges it for a device token and
walks your cloud library. The cloud walk and handwriting rasterization are
reverse-engineered, so expect to iterate against your device.

### Doppler keys

Add these to the Doppler `sync-bar` project (config `dev`). Leave Google's empty
until that client is implemented.

| Key | From |
|-----|------|
| `NOTION_CLIENT_ID` | Notion integration |
| `NOTION_CLIENT_SECRET` | Notion integration |
| `LINEAR_CLIENT_ID` | Linear OAuth application |
| `LINEAR_CLIENT_SECRET` | Linear OAuth application |
| `GOOGLE_CLIENT_ID` | Google Cloud OAuth client (optional for now) |
| `GOOGLE_CLIENT_SECRET` | Google Cloud OAuth client (optional for now) |

Then run `./scripts/pull-secrets.sh` and rebuild.

## License

Copyright 2026 Strategic Nerds.
