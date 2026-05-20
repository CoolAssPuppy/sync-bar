# SyncBar: spec for overnight build

## Read this first

This document is the single source of truth for the overnight build of SyncBar, a macOS menu bar app that syncs reMarkable notes to Notion. Re-read the relevant section at the start of every phase. Do not deviate. If a real situation contradicts this spec, stop and write the contradiction to `/tasks/lessons.md` for resolution by the human in the morning.

The agent executing this is Claude Code with the user's CLAUDE.md configuration. Apply the workflow in that file: plan mode, subagents for exploration, self-improvement loop, verification before done, simplicity first, no laziness. This spec assumes those defaults.

Each phase has hard acceptance criteria. **A phase is not "done" until every checkbox in its Acceptance Gate runs green.** Do not advance to the next phase until the previous one passes.

The reMarkable device is not yet in the user's possession. All reMarkable integration is built and tested against mocks and recorded fixtures. The user will pair the device after it arrives. The UI for pre-pairing states (the "Connect your reMarkable" screen) must be functional from day one.

## Section 1: Core decisions (do not relitigate)

| Decision | Choice |
|---|---|
| Platform | macOS menu bar app, SwiftUI |
| Bundle ID | `com.strategicnerds.syncbar` |
| App name | SyncBar |
| Distribution | Downloadable, signed, notarized, Sparkle for updates |
| App auth | None. No sign-in to SyncBar itself. |
| Ledger storage | CloudKit private database (per Apple ID) |
| Token storage | iCloud Keychain (per Apple ID) |
| Settings storage | CloudKit private database |
| OCR default | Apple Vision framework, on-device |
| OCR optional upgrade | OpenAI or Anthropic API, user-supplied key in iCloud Keychain |
| Sync trigger | Background timer, user-configurable interval |
| Sync direction | One-way: reMarkable → Notion |
| Granularity | Per reMarkable page |
| Notion accounts | Multiple workspaces supported |
| reMarkable accounts | One per Apple ID |
| Notebook list refresh | On every app open and every Settings close |
| Conventions | Mirror MailNotifier, MeetingNotifier, LinearBar |
| Build pipeline | Command-line scripts. Xcode never required to open. |
| Style | Sentence case headers, no emoji, no emdashes, 6th-grade language |

## Section 2: The very first task

**Before writing any SyncBar code:**

1. Locate MailNotifier, MeetingNotifier, and LinearBar repos on this machine. Likely paths: `~/code/`, `~/Developer/`, `~/projects/`, `~/strategicnerds/`. Ask the human if they cannot be found.
2. Read all three repos in full. Use subagents in parallel if useful.
3. Extract conventions into a new file `/tasks/conventions.md` covering, at minimum:
   - Project layout (Xcode project vs. Swift Package Manager, folder hierarchy)
   - Build pipeline (Makefile, justfile, shell scripts, Fastlane)
   - Code signing approach
   - Notarization approach
   - Sparkle (or equivalent) update setup
   - Bundle versioning conventions
   - Design tokens (colors, fonts, spacing, dark/light handling)
   - View architecture pattern (MVVM, Coordinators, etc.)
   - State management (Combine, Observation, @Observable, @AppStorage, etc.)
   - Async patterns (async/await, Combine, callbacks)
   - Persistence patterns (CloudKit, SwiftData, GRDB, Core Data)
   - Keychain wrapper pattern
   - Logging (os.log, swift-log, etc.)
   - Testing layout (XCTest layout, mock patterns, fixture handling)
   - SwiftLint or SwiftFormat config
   - GitHub Actions or other CI config
   - Menu bar app patterns (status item construction, popover vs. window, settings window)
   - Window management
   - Launch at login (SMAppService usage)
4. Identify any patterns that are inconsistent across the three apps. Choose the most recent or most refined version. Note the choice in `/tasks/conventions.md` with rationale.
5. **Acceptance check before continuing:** `/tasks/conventions.md` must exist and cover every bullet above. Present a summary to the human in `/tasks/todo.md`'s status section before writing any SyncBar code.

**Treat `/tasks/conventions.md` as binding for all subsequent phases.** This spec describes *what* to build. `/tasks/conventions.md` describes *how* to build it in a way that matches the user's existing apps.

If any guidance in this spec conflicts with `/tasks/conventions.md`, the conventions file wins for style/structure questions. This spec wins for functional requirements.

## Section 3: Repository structure (high-level guidance)

The exact directory layout will follow MailNotifier's conventions. If MailNotifier uses Swift Package Manager with a single executable target, do the same. If it uses an Xcode project with a workspace and modular packages, do the same.

What the repo must contain in some form:

```
SyncBar/                    (or whatever name matches MailNotifier convention)
  App/                        # @main entry point, AppDelegate, SyncBarApp.swift
  Features/                   # One folder per feature
    MenuBar/
    MainWindow/
    Onboarding/
    NotebookList/
    RulesSheet/
    Settings/
    Log/
  Packages/                   # Or "Modules/" or whatever MailNotifier uses
    RemarkableKit/            # reMarkable cloud client, pure Swift, no UI
    NotionKit/                # Notion API client
    OcrKit/                   # Vision + provider abstraction for OpenAI/Anthropic
    RulesEngine/              # Pure logic, no I/O
    SyncCore/                 # Orchestrates a sync cycle
    LedgerKit/                # CloudKit wrapper for the sync ledger
    KeychainKit/              # iCloud Keychain wrapper (or shared with other apps)
    DesignSystem/             # Tokens, components, matches MailNotifier
  Resources/
    Assets.xcassets
    Localizable.strings
  Tests/
    SyncBarTests/           # App-level unit tests
    Each Package has its own Tests/ folder
  Scripts/
    build.sh                  # Or makefile, justfile
    release.sh
    bootstrap.sh
    test.sh
    lint.sh
  .github/
    workflows/                # Mirror MailNotifier's CI exactly
  tasks/
    todo.md
    lessons.md
    conventions.md
  README.md
  CONTRIBUTING.md
  ARCHITECTURE.md
  SECURITY.md
  CHANGELOG.md
  .gitignore
  .swiftlint.yml              # If MailNotifier uses one
  Package.swift               # If using SPM
  Project.yml or .xcodeproj   # If using XcodeGen or Xcode project
```

## Section 4: Bundle identifiers and versioning

- App bundle ID: `com.strategicnerds.syncbar`
- Module bundle IDs: `com.strategicnerds.syncbar.<modulename>` (lowercase)
- Sparkle feed: follow MailNotifier convention (likely `appcast.xml` hosted somewhere on strategicnerds.com)
- Version scheme: follow MailNotifier convention. If MailNotifier uses semantic versioning with build numbers, do the same. Start at `0.1.0` build `1`.
- CloudKit container ID: `iCloud.com.strategicnerds.syncbar`
- Keychain access group: follow MailNotifier convention. If shared across apps for some reason, document why and how SyncBar participates. Otherwise use a per-app access group named `com.strategicnerds.syncbar`.

## Section 5: Architecture overview

```
  ┌─────────────────────────────────────────────────────────────┐
  │                    SwiftUI App Layer                        │
  │                                                             │
  │   MenuBar (NSStatusItem)        MainWindow                  │
  │       │                              │                      │
  │       ▼                              ▼                      │
  │   MenuBarViewModel             MainWindowViewModel          │
  │       │                              │                      │
  └───────┼──────────────────────────────┼──────────────────────┘
          │                              │
          └──────────────┬───────────────┘
                         ▼
        ┌─────────────────────────────────────┐
        │           SyncCoordinator           │
        │  (single source of truth for sync)  │
        └─────────────────────────────────────┘
              │            │           │
       ┌──────┘            │           └──────┐
       ▼                   ▼                   ▼
  ┌─────────┐      ┌──────────────┐    ┌──────────────┐
  │ Sync    │      │   Ledger     │    │  Settings    │
  │ Engine  │◄────►│   Service    │◄──►│   Service    │
  └─────────┘      │  (CloudKit)  │    │  (CloudKit)  │
   │  │  │  │      └──────────────┘    └──────────────┘
   │  │  │  │
   │  │  │  └──► NotionKit ────► Notion API
   │  │  └─────► OcrKit ────────► Apple Vision / OpenAI / Anthropic
   │  └────────► RemarkableKit ─► reMarkable cloud
   └───────────► RulesEngine    (pure, no I/O)

         ┌─────────────────────────┐
         │   KeychainKit (iCloud)  │  ◄── all secrets
         └─────────────────────────┘
```

### Single source of truth: SyncCoordinator

One `@MainActor` `SyncCoordinator` actor holds the app's runtime state and orchestrates sync cycles. It is owned by the App and injected via environment.

### Background sync

A `SyncTimer` owned by `SyncCoordinator` fires at user-configured intervals using `Timer.publish` (or whatever async timing pattern MailNotifier uses). When the app is in the background but running, the timer continues. macOS does not require special background entitlements for menu bar apps that keep running; the activation policy is `.accessory` (no Dock icon, runs in background indefinitely as long as user is logged in).

### What's a "sync cycle"

```
SyncCoordinator.tick()
├── Refresh user tokens if expiring
├── For each enabled Rule:
│    ├── Fetch latest pages from reMarkable cloud
│    ├── Diff against Ledger
│    ├── For each page needing action:
│    │    ├── Download notebook PDF (cached for cycle)
│    │    ├── Rasterize relevant page
│    │    ├── Run OCR (Vision by default, fall back to API if configured)
│    │    ├── RulesEngine.evaluate() → SyncDirective
│    │    ├── Execute directive via NotionKit
│    │    └── Upsert SyncedPage in Ledger, write SyncEvent
│    └── Mark orphaned pages
└── Persist last-tick timestamp
```

## Section 6: Data model

All persistent data lives in CloudKit private database under the `iCloud.com.strategicnerds.syncbar` container. Schema is declared in code (CKModelTypes or similar Swift wrappers).

### Record types

#### `RemarkableAccount`

| Field | Type | Notes |
|---|---|---|
| `recordName` | CKRecord.ID | Singleton: `"singleton"` |
| `pairedAt` | Date | When the one-time code was exchanged |
| `userIdentifier` | String | Opaque id surfaced by reMarkable API; for display only |
| `lastSyncedAt` | Date? | Latest successful sync across all rules |

Tokens are NOT stored here. They live in iCloud Keychain.

#### `NotionAccount`

| Field | Type | Notes |
|---|---|---|
| `recordName` | CKRecord.ID | UUID |
| `workspaceId` | String | Notion's workspace UUID |
| `workspaceName` | String | Display only |
| `workspaceIcon` | String? | Emoji or URL |
| `botId` | String | From Notion OAuth response |
| `connectedAt` | Date | |
| `lastCatalogRefreshAt` | Date? | |

Access token NOT stored here. Lives in iCloud Keychain keyed by `workspaceId`.

#### `Rule`

| Field | Type | Notes |
|---|---|---|
| `recordName` | CKRecord.ID | UUID |
| `enabled` | Bool | Default true |
| `rmNotebookId` | String | reMarkable doc UUID |
| `rmNotebookName` | String | Display only, refreshed on app open |
| `notionAccountRecordName` | String | References `NotionAccount.recordName` |
| `destinationId` | String | Notion page or database id |
| `destinationType` | String | "page" or "database" |
| `destinationTitle` | String | Display only |
| `destinationSchema` | Data? | Encoded JSON of database schema (for picker pre-fill) |
| `titleStrategy` | String | "first_line_of_ocr", "template", "page_n", "rm_created_date" |
| `titleTemplate` | String? | Used when titleStrategy == "template" |
| `pageOrder` | String | "chronological" or "reverse_chronological" |
| `ocrMode` | String | "all", "handwritten_only", "none" |
| `savePdfAttachment` | Bool | If true, attach the rendered PDF to the Notion page |
| `propertyMappings` | Data? | Encoded JSON describing column population for databases |
| `createdAt` | Date | |
| `updatedAt` | Date | |

#### `SyncedPage`

| Field | Type | Notes |
|---|---|---|
| `recordName` | CKRecord.ID | Composite-derived: `"\(rmNotebookId)-\(rmPageId)"` |
| `ruleRecordName` | String | References `Rule.recordName` |
| `rmNotebookId` | String | |
| `rmPageId` | String | |
| `rmPageCreatedAt` | Date? | |
| `rmPageModifiedAt` | Date? | |
| `rmVersionHash` | String? | Content fingerprint |
| `notionPageId` | String? | Notion page or row id |
| `notionPageURL` | String? | Click-through link |
| `notionLastWrittenAt` | Date? | |
| `lastSyncedAt` | Date? | |
| `status` | String | "idle", "error", "orphaned" |
| `lastError` | String? | |

Index on `(rmNotebookId, rmPageId)` for fast lookup during diff.

#### `SyncEvent`

| Field | Type | Notes |
|---|---|---|
| `recordName` | CKRecord.ID | UUID |
| `occurredAt` | Date | |
| `ruleRecordName` | String? | May be null if rule was deleted |
| `eventType` | String | "page_synced", "page_failed", "rule_run_started", "rule_run_completed", "token_refreshed", "orphan_detected" |
| `rmNotebookId` | String? | |
| `rmPageId` | String? | |
| `notionPageURL` | String? | |
| `durationMs` | Int64? | |
| `ocrUsed` | Bool? | |
| `ocrProvider` | String? | "vision", "openai", "anthropic" |
| `ocrTokensIn` | Int64? | |
| `ocrTokensOut` | Int64? | |
| `errorMessage` | String? | |

Index on `occurredAt` descending.

#### `AppSettings`

| Field | Type | Notes |
|---|---|---|
| `recordName` | CKRecord.ID | Singleton: `"singleton"` |
| `syncIntervalSeconds` | Int | Default 900 (15 min). User-configurable. |
| `launchAtStartup` | Bool | Default true. Mirrored to SMAppService. |
| `ocrProvider` | String | "vision" (default), "openai", "anthropic" |
| `ocrModel` | String? | E.g., "gpt-4o" or "claude-3-5-sonnet". Optional. |
| `notifyOnSyncFailure` | Bool | Default true. Sends a user notification. |
| `notifyOnSyncSuccess` | Bool | Default false. |
| `lastLedgerExportAt` | Date? | For the manual export feature |
| `appearance` | String | "system", "light", "dark"; default "system" |

### Keychain layout (iCloud Keychain)

Service identifier: `com.strategicnerds.syncbar`
Accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` for tokens that should not iCloud-sync, OR `kSecAttrAccessibleAfterFirstUnlock` with `kSecAttrSynchronizable = true` for tokens that should sync across the user's Macs.

**Decision: tokens that need to sync across machines must be marked synchronizable.** All four token kinds below are synchronizable.

| Account name | Service | Purpose |
|---|---|---|
| `remarkable.device_token` | `com.strategicnerds.syncbar` | reMarkable long-lived device token |
| `remarkable.user_token` | `com.strategicnerds.syncbar` | reMarkable short-lived user token |
| `notion.workspace.<workspaceId>.access_token` | `com.strategicnerds.syncbar` | Per-Notion-workspace access token |
| `ocr.openai.api_key` | `com.strategicnerds.syncbar` | Optional |
| `ocr.anthropic.api_key` | `com.strategicnerds.syncbar` | Optional |

`KeychainKit` exposes typed accessors so callers never deal with raw service/account strings.

## Section 7: Packages (Swift Package Manager modules)

Each package below is independently testable. Public APIs only listed; internal helpers are private to the package.

Each package's documentation lives in `Packages/<Name>/README.md` with:
- One-paragraph purpose
- Public API summary
- Test strategy

### RemarkableKit

Pure Swift, no UIKit/AppKit. URLSession for HTTP. Codable for parsing.

```swift
public protocol RemarkableClient {
    func pairDevice(oneTimeCode: String) async throws -> DeviceToken
    func refreshUserToken(deviceToken: DeviceToken) async throws -> UserToken
    func listNotebooks(userToken: UserToken) async throws -> [RmNotebook]
    func listPages(userToken: UserToken, notebookId: String) async throws -> [RmPage]
    func downloadNotebookPdf(userToken: UserToken, notebookId: String) async throws -> Data
}

public final class LiveRemarkableClient: RemarkableClient { /* ... */ }

public struct DeviceToken: Sendable { public let value: String }
public struct UserToken: Sendable {
    public let value: String
    public let expiresAt: Date
}

public struct RmNotebook: Sendable, Hashable {
    public let id: String
    public let name: String
    public let parentFolder: String?
    public let lastModified: Date
}

public struct RmPage: Sendable, Hashable {
    public let notebookId: String
    public let pageId: String
    public let positionInNotebook: Int
    public let createdAt: Date
    public let modifiedAt: Date
    public let hasTypedText: Bool
    public let versionHash: String
}

public enum RemarkableError: Error, Sendable {
    case invalidOneTimeCode
    case deviceTokenExpired
    case userTokenExpired
    case rateLimited(retryAfter: TimeInterval?)
    case network(underlying: Error)
    case unexpectedResponse(String)
}
```

Mock: `MockRemarkableClient` for tests. Fixture loader reads from `Tests/Fixtures/Remarkable/`.

### NotionKit

```swift
public protocol NotionClient {
    func exchangeCodeForToken(code: String, redirectUri: String) async throws -> NotionConnection
    func listAccessiblePages(token: String) async throws -> [NotionDestination]
    func listAccessibleDatabases(token: String) async throws -> [NotionDestination]
    func getDatabaseSchema(databaseId: String, token: String) async throws -> NotionDatabaseSchema
    func createPageUnderParent(parentId: String, params: CreatePageParams, token: String) async throws -> NotionPageRef
    func createDatabaseRow(databaseId: String, params: CreateRowParams, token: String) async throws -> NotionPageRef
    func updatePage(pageId: String, params: UpdatePageParams, token: String) async throws
    func appendImageToPage(pageId: String, imageData: Data, token: String) async throws
    func appendFileToPage(pageId: String, fileData: Data, filename: String, token: String) async throws
}

public final class LiveNotionClient: NotionClient { /* ... */ }

public struct NotionConnection: Sendable {
    public let workspaceId: String
    public let workspaceName: String
    public let workspaceIcon: String?
    public let botId: String
    public let accessToken: String
}

public struct NotionDestination: Sendable, Hashable {
    public let id: String
    public let type: DestinationType
    public let title: String
    public let icon: String?
    public let parentPath: String?
}

public enum DestinationType: String, Sendable { case page, database }

public struct NotionDatabaseSchema: Sendable, Codable, Hashable {
    public let properties: [NotionDatabaseProperty]
}

public struct NotionDatabaseProperty: Sendable, Codable, Hashable {
    public let name: String
    public let type: String
    public let options: [NotionSelectOption]?
}

public struct NotionSelectOption: Sendable, Codable, Hashable {
    public let id: String
    public let name: String
    public let color: String?
}

public struct CreatePageParams: Sendable { /* title, blocks */ }
public struct CreateRowParams: Sendable { /* properties, blocks */ }
public struct UpdatePageParams: Sendable { /* title?, properties?, blocks? */ }
public struct NotionPageRef: Sendable { public let id: String; public let url: String }

public enum NotionError: Error, Sendable {
    case authorizationFailed
    case rateLimited(retryAfter: TimeInterval?)
    case pageNotFound
    case validationFailed(message: String)
    case network(underlying: Error)
}
```

OAuth: Notion's OAuth flow requires a redirect URI. Use a localhost HTTP server bound on a high port, opened only during the OAuth flow. Pattern: `ASWebAuthenticationSession` with `start(usingHTTPSchemeFor:)` if MailNotifier uses it; otherwise a transient `NSHTTPServer` (via Network.framework). Determine from MailNotifier conventions.

### OcrKit

```swift
public protocol OcrProvider: Sendable {
    var name: String { get }   // "vision", "openai", "anthropic"
    func transcribe(imageData: Data) async throws -> OcrResult
}

public struct OcrResult: Sendable {
    public let text: String
    public let provider: String
    public let model: String?
    public let tokensIn: Int?
    public let tokensOut: Int?
}

public enum OcrError: Error, Sendable {
    case visionFailed(underlying: Error)
    case providerKeyMissing
    case providerRefused(reason: String)
    case rateLimited(retryAfter: TimeInterval?)
    case network(underlying: Error)
}

public final class VisionOcrProvider: OcrProvider { /* uses VNRecognizeTextRequest */ }
public final class OpenAIOcrProvider: OcrProvider { /* uses GPT-4o-class vision endpoint */ }
public final class AnthropicOcrProvider: OcrProvider { /* uses Claude vision */ }

public enum OcrProviderFactory {
    public static func make(
        provider: String,
        model: String?,
        keychain: KeychainReading
    ) throws -> OcrProvider
}
```

Default OCR prompt for LLM providers (constant in `OcrKit`):

```
You are transcribing a handwritten or typed note from a reMarkable tablet.

Rules:
- Output only the transcription. No commentary. No markdown formatting.
- Preserve line breaks exactly as written.
- If a word is unclear, write [?] in its place.
- If the page appears blank, output exactly: [blank page]
- If the page is a diagram or sketch with no text, output exactly: [diagram]
- Do not invent text that is not visible.
```

Vision provider has no prompt; it returns recognized text directly. Apply minimal post-processing (trim trailing newlines, collapse triple-newlines).

### RulesEngine

Pure logic. No I/O. Highest test coverage target.

```swift
public struct RulesEngine: Sendable {
    public init() {}

    public func evaluate(
        rule: Rule,
        page: RmPage,
        ocrText: String?,
        existingState: SyncedPageState?,
        notebookName: String
    ) -> SyncDirective
}

public struct SyncedPageState: Sendable, Hashable {
    public let rmVersionHash: String?
    public let notionPageId: String?
}

public enum SyncDirective: Sendable {
    case create(NotionPayload)
    case update(notionPageId: String, payload: NotionPayload)
    case skip(reason: SkipReason)
    case markOrphan
}

public struct NotionPayload: Sendable {
    public let title: String
    public let propertyValues: [String: NotionPropertyValue]
    public let blocks: [NotionBlock]
    public let pdfAttachment: Data?
}

public enum SkipReason: Sendable {
    case unchanged
    case ocrSkippedAndPageEmpty
}

public enum NotionPropertyValue: Sendable, Hashable {
    case title(String)
    case richText(String)
    case multiSelect([String])
    case select(String)
    case status(String)
    case date(start: Date, end: Date?)
    case checkbox(Bool)
    case number(Double)
    case url(String)
    case email(String)
    case phoneNumber(String)
}

public enum NotionBlock: Sendable, Hashable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case image(Data)
}
```

### SyncCore

```swift
@MainActor
public final class SyncCoordinator: ObservableObject {
    public init(
        ledger: LedgerService,
        remarkable: RemarkableClient,
        notion: NotionClient,
        ocrFactory: OcrProviderFactory.Type,
        keychain: KeychainReading,
        settings: SettingsService,
        rulesEngine: RulesEngine,
        clock: any ClockProtocol = SystemClock()
    )

    public func start()
    public func stop()
    public func syncNow(ruleId: String?) async

    @Published public private(set) var isSyncing: Bool
    @Published public private(set) var lastTickAt: Date?
    @Published public private(set) var nextTickAt: Date?
}
```

### LedgerService

Wraps CloudKit private DB. All access goes through this service. No direct CKContainer use elsewhere.

```swift
public protocol LedgerService: Sendable {
    func upsertSyncedPage(_ page: SyncedPageRecord) async throws
    func loadSyncedPage(rmNotebookId: String, rmPageId: String) async throws -> SyncedPageRecord?
    func listSyncedPages(forRule ruleId: String) async throws -> [SyncedPageRecord]
    func appendEvent(_ event: SyncEventRecord) async throws
    func listRecentEvents(limit: Int) async throws -> [SyncEventRecord]

    // Rules
    func listRules() async throws -> [RuleRecord]
    func upsertRule(_ rule: RuleRecord) async throws
    func deleteRule(id: String) async throws

    // Accounts
    func loadRemarkableAccount() async throws -> RemarkableAccountRecord?
    func upsertRemarkableAccount(_ account: RemarkableAccountRecord) async throws
    func listNotionAccounts() async throws -> [NotionAccountRecord]
    func upsertNotionAccount(_ account: NotionAccountRecord) async throws
    func deleteNotionAccount(id: String) async throws

    // Settings
    func loadSettings() async throws -> AppSettingsRecord
    func upsertSettings(_ settings: AppSettingsRecord) async throws

    // Export
    func exportSnapshotJson() async throws -> Data
}

public final class CloudKitLedgerService: LedgerService { /* ... */ }
public final class InMemoryLedgerService: LedgerService { /* used in tests */ }
```

### KeychainKit

```swift
public protocol KeychainReading: Sendable {
    func get(account: String, service: String) throws -> String?
}

public protocol KeychainWriting: KeychainReading {
    func set(_ value: String, account: String, service: String, synchronizable: Bool) throws
    func delete(account: String, service: String) throws
}

public final class ICloudKeychain: KeychainWriting { /* ... */ }
public final class InMemoryKeychain: KeychainWriting { /* used in tests */ }

public extension KeychainReading {
    func remarkableDeviceToken() throws -> String? { /* ... */ }
    func notionWorkspaceToken(workspaceId: String) throws -> String? { /* ... */ }
    // ... typed accessors per Section 6
}
```

### DesignSystem

Tokens, components, modifiers. Mirror MailNotifier exactly. If MailNotifier has a `DesignSystem` package, share an identical structure. If MailNotifier embeds design in the app target, do the same.

## Section 8: UI specification

### Menu bar item

- `NSStatusItem` with variable-length width
- Icon: SF Symbol `arrow.triangle.2.circlepath` by default. Match style of MailNotifier's icon presentation (template image, tint behavior).
- Click behavior: opens the main window if closed, brings it to front if open. Right-click or option-click reveals a menu with: "Sync now", "Open SyncBar", "Pause syncing", "Settings", "Quit SyncBar".
- Status indication: when syncing, animate the icon (rotate or pulse, matching MailNotifier's loading style).

### Main window

Single window. Resizable. Minimum 900x600. Saved size and position. Window mirrors MailNotifier's overall chrome and color treatment.

Layout: a three-region structure.

```
┌─────────────────────────────────────────────────────────────────┐
│  Sidebar         │   Notebook list           │  Rules sheet     │
│  (left)          │   (center)                │  (slides over    │
│                  │                           │   bottom of      │
│  Accounts        │   reMarkable notebooks    │   notebook list  │
│                  │                           │   when notebook  │
│  - reMarkable    │   Notebook A              │   is selected)   │
│  - Notion (1)    │   Notebook B              │                  │
│  - Notion (2)    │   Notebook C              │                  │
│  + Add Notion    │   ...                     │                  │
│                  │                           │                  │
│  --------        │                           │                  │
│                  │                           │                  │
│  Sync log        │                           │                  │
│  Settings        │                           │                  │
└─────────────────────────────────────────────────────────────────┘
```

#### Sidebar

- "Accounts" section, listing one reMarkable account row (or "Not connected") and N Notion workspace rows.
- Below: "Add Notion workspace" button.
- Divider.
- Two nav items: "Sync log" and "Settings".

When clicked, the right panes update accordingly. When "Sync log" is selected, the notebook list area is replaced by the log view. When "Settings" is selected, settings open in a separate window matching MailNotifier's settings window convention (likely `Settings` scene in SwiftUI with tabs).

#### Notebook list

- Refreshes on every app launch and on every Settings window close.
- Each row shows: notebook name, parent folder if any, last modified, status badge (Active rule / No rule / Synced X minutes ago).
- Clicking a row selects the notebook and opens the Rules sheet.
- Empty state if reMarkable is not connected: "Connect your reMarkable to see your notebooks" with a button to start pairing.
- Empty state if connected but no notebooks: "No notebooks found. Refresh, or create one on your reMarkable."

#### Rules sheet (the slide-up panel)

When a notebook is clicked, a panel slides up from below the notebook list (the implementation choice — disclosure expansion vs. `.sheet` modal vs. side detail pane — follows MailNotifier's idiom for similar interactions). Default to a non-modal panel that pushes the notebook list up; if MailNotifier uses sheets, use `.sheet`.

Contents of the sheet:

1. **Destination**
   - Workspace picker (dropdown of connected Notion workspaces)
   - Destination picker (dropdown of pages and databases in that workspace, lazy-loaded)
   - When the destination is a database, a "Refresh schema" button appears

2. **Title**
   - Title strategy radio: First line of OCR / Template / Page number / reMarkable date
   - If Template selected: text field with token hints (`{notebook}`, `{date}`, `{page_n}`)

3. **OCR**
   - OCR mode radio: All pages / Handwritten only / None
   - Provider override (optional): use Settings default, or override to Vision/OpenAI/Anthropic for this rule

4. **Output**
   - Save PDF attachment checkbox
   - Page order radio (only relevant for "page" destinations): Chronological / Reverse chronological

5. **Database field mapping** (only shown when destination is a database)
   - For each property in the destination schema (excluding the title property), show a row:
     - Property name and type
     - "Set to" picker with options depending on type:
       - select / status: pick one option from the available list
       - multi_select: pick zero or more options
       - date: "Use page created date" / "Use page modified date" / "Use sync date" / "Leave blank"
       - text / rich_text: free text (with template tokens)
       - checkbox: true / false / "Leave blank"
       - number: literal number or "Page number" or "Leave blank"
       - url / email / phone_number: literal or template

6. **Buttons**
   - "Sync now" (only enabled if rule is saved and valid)
   - "Save rule"
   - "Disable rule" (only shown if rule is enabled and saved)
   - "Delete rule" (only shown if rule exists)

### Onboarding flow

Triggered on first launch when no reMarkable account and no Notion accounts exist. Also accessible from the sidebar.

Three steps:

1. **Welcome to SyncBar** — One-line tagline, "Get started" button.
2. **Connect your reMarkable** — Explainer text. "I have a one-time code" text field with a help button explaining where to generate it. "I'll do this later" button. (For pre-pairing flow.)
3. **Connect a Notion workspace** — "Connect Notion" button launches OAuth. After return, ask "Add another?" / "Done".

After onboarding, focus moves to the main window's notebook list.

### Settings window

Separate from main window. Tabs (or sidebar, matching MailNotifier):

- **General**
  - Launch at startup (checkbox, wired to SMAppService)
  - Sync interval (picker: 5 min, 15 min, 30 min, 1 hour, 4 hours, manual only)
  - Appearance (System / Light / Dark)
  - Notifications:
    - Notify on sync failure (checkbox, default on)
    - Notify on sync success (checkbox, default off)

- **OCR**
  - Default provider: Apple Vision (recommended) / OpenAI / Anthropic
  - If OpenAI: API key field (Keychain-backed, masked, "Test connection" button)
  - If Anthropic: API key field (Keychain-backed, masked, "Test connection" button)
  - Model selector if applicable

- **Accounts** (mirror of sidebar but with full management UI)
  - reMarkable: status, disconnect button, re-pair button
  - Notion workspaces list with disconnect-per-workspace

- **Data**
  - "Export ledger as JSON" button → save panel → writes a JSON snapshot of all CloudKit records
  - "Last exported" timestamp
  - "Erase local cache" button (clears any local cache; CloudKit data is preserved)

- **Advanced**
  - Log verbosity
  - Open log folder
  - Reset to defaults

When Settings closes, the main window's notebook list refreshes automatically.

### Sync log view

Replaces the notebook list when "Sync log" is selected from the sidebar.

- Filterable by rule, by event type, by date range.
- Most recent first.
- Each row: timestamp, event type pill, rule name, notebook name, optional Notion URL (click to open), duration, OCR provider, error message if any.
- No content. Identifiers and metadata only.
- "Clear log" button (with confirm) deletes all SyncEvent records.

## Section 9: Conventions inherited from MailNotifier

The agent must extract and follow these from MailNotifier:

| Item | Source of truth |
|---|---|
| Project layout | MailNotifier |
| Build script | MailNotifier's `Scripts/build.sh` or equivalent |
| Release pipeline (sign, notarize, package, appcast) | MailNotifier |
| GitHub Actions workflow | MailNotifier |
| Sparkle setup | MailNotifier |
| Window chrome and design tokens | MailNotifier |
| Menu bar status item pattern | MailNotifier |
| Settings window pattern | MailNotifier |
| Launch-at-login implementation | MailNotifier |
| Logging | MailNotifier |
| Keychain wrapper | MailNotifier (if shareable; otherwise mirror its pattern) |
| Testing layout | MailNotifier |
| SwiftLint config | MailNotifier |

The `/tasks/conventions.md` file from Section 2 captures these explicitly with paths and snippets.

## Section 10: Testing strategy

### Discipline

Test-driven development is the default workflow. For every type and function the agent writes:

1. Write the test file first with at least one failing test.
2. Run the test, observe failure.
3. Implement.
4. Run the test, observe pass.
5. Refactor if needed; tests must still pass.
6. Commit.

Commits must contain both test and implementation. A commit with implementation but no test is invalid.

### Test pyramid

```
                  UI tests (XCUITest)
                /                    \
       Integration tests             Snapshot tests
       (real CloudKit local,         (SwiftUI views)
        mocked external APIs)
              /                              \
    Unit tests (XCTest, per package)
```

### Unit tests

Location: `Packages/<Name>/Tests/<Name>Tests/`. One test file per source file. Mocks live in `Packages/<Name>/Tests/<Name>Tests/Mocks/`.

Coverage targets (enforced via Xcode test plan):
- `RulesEngine`: 95%
- `SyncCore`: 85%
- `RemarkableKit`, `NotionKit`: 80%
- `OcrKit`: 80%
- `LedgerKit`, `KeychainKit`: 80%
- App targets: 60% (UI-heavy)

For every public function in every package, write at minimum:
1. A happy-path test
2. An error-path test for each documented error
3. An edge-case test for boundary inputs

### Integration tests

Location: `Tests/IntegrationTests/`. Use CloudKit's local simulator support where available. External APIs (reMarkable, Notion, OpenAI, Anthropic) mocked at the HTTP layer.

Required integration tests:

- `OnboardingTests` — Complete pre-pair onboarding, complete with mocked pairing
- `RuleCrudTests` — Create, edit, delete a rule; assert CloudKit state
- `RulesEngineCatalogIntegrationTests` — Refresh Notion destinations into the picker, assert schema is queryable
- `SyncCycleHappyPathTests` — Mocked notebook with 3 pages syncs to mocked Notion; verify SyncedPage and SyncEvent records
- `SyncCycleIdempotencyTests` — Run twice, no duplicate writes
- `SyncCycleModifiedPageTests` — Bump version hash, sync, Notion update called once
- `SyncCycleOrphanDetectionTests` — Page removed from rM, status becomes orphaned
- `SyncCycleSchedulerTests` — Timer fires at configured interval
- `KeychainCrossAccountTests` — Storing two Notion workspace tokens does not collide
- `LedgerExportTests` — Export produces valid JSON snapshot of all records

### Snapshot tests

Location: `Tests/SnapshotTests/`. Use Point-Free's `swift-snapshot-testing` if MailNotifier uses it; otherwise mirror MailNotifier's approach.

Snapshots for:
- Main window in three states: not-connected, no-notebooks, populated-with-rules
- Rules sheet for page destination
- Rules sheet for database destination with multi-select property
- Settings window: General, OCR, Accounts, Data, Advanced
- Sync log with mixed events
- Empty state screens
- Dark mode variants of all above

### UI tests (XCUITest)

Six critical journeys:

1. `OnboardingPrePairFlowUITest` — Skip reMarkable, connect Notion, see notebook empty state with "connect your reMarkable" CTA
2. `OnboardingWithMockedPairFlowUITest` — Enter one-time code (mocked endpoint returns success), connect Notion, see notebooks
3. `CreateRuleForDatabaseUITest` — Select notebook, configure rule pointing at a mock database with two property mappings, save, see badge
4. `SyncNowAndLogUITest` — Click "Sync now" on a rule, see event appear in sync log
5. `ProvideOpenAIKeyUITest` — Enter OpenAI key in Settings, see masked display on reload, run a sync that uses OpenAI
6. `DisconnectNotionWorkspaceUITest` — Disconnect a workspace, see affected rules disabled with messaging

All UI tests use a mock launcher mode (launch argument `--mock-mode`) that swaps live clients for mocks and uses `InMemoryLedgerService` plus `InMemoryKeychain` so tests don't touch real CloudKit.

### CI

CI runs on GitHub Actions, mirroring MailNotifier's workflow. Jobs:

1. Lint (SwiftLint or SwiftFormat)
2. Build (Debug)
3. Unit tests across all packages
4. Snapshot tests
5. Integration tests
6. UI tests
7. Build release (no signing in CI; signing happens on release machine)

Budget: green pipeline in under 15 minutes. Shard tests if exceeded.

## Section 11: Build and release pipeline

The agent must mirror MailNotifier's pipeline exactly. Whatever tooling MailNotifier uses (Tuist, XcodeGen, plain xcodebuild, fastlane, just), do the same.

The user must never need to open Xcode. All of the following commands must work from the terminal:

- `make bootstrap` (or `just bootstrap`) — install deps, generate project if needed, create `Config.local.xcconfig` from template
- `make build` — debug build
- `make test` — run all tests
- `make ui-test` — run UI tests (separate because they're slower)
- `make lint` — run SwiftLint
- `make format` — run SwiftFormat
- `make release` — sign, notarize, package as DMG, generate appcast entry, ready to publish
- `make run` — launch the built app
- `make clean` — remove build artifacts

If MailNotifier uses different verbs (e.g., `just`, `fastlane`), match those instead.

Code signing:
- Developer ID Application certificate
- Hardened runtime entitlements: `com.apple.security.app-sandbox` (true), iCloud (`com.apple.developer.icloud-container-identifiers`, `com.apple.developer.icloud-services`), Keychain Sharing (if needed), Apple Events (only if needed), Network (client connections), App Group (if used in MailNotifier)
- Notarization via `notarytool` (Apple's modern command-line notarization tool), credentials read from Keychain via App-Specific Password

Sparkle setup:
- EdDSA-signed appcast
- Appcast hosted at the URL MailNotifier uses for its own appcast (subpath like `/syncbar/appcast.xml`)
- Public key embedded in app bundle
- Private key stored in user's Keychain on release machine; `make release` reads it from there

## Section 12: Code quality gates

Per-commit (pre-commit hook):
- SwiftFormat
- SwiftLint with `--strict`
- Quick unit tests for changed packages

Per-PR / per-build:
- All CI jobs above

Invariants enforced (some via SwiftLint custom rules, some via build-script greps):

| Invariant | How |
|---|---|
| No force unwraps in production code | SwiftLint `force_unwrapping` |
| No `print()` statements in production code | SwiftLint `no_print_ln` |
| No `TODO` or `FIXME` left at release | Build script grep, blocks release if found |
| No raw CKContainer use outside LedgerKit | Custom SwiftLint rule or build-script grep |
| No URLSession use outside RemarkableKit, NotionKit, OcrKit | Build-script grep |
| No SecItemAdd/Update/Copy outside KeychainKit | Build-script grep |
| No file over 400 lines | SwiftLint `file_length` |
| No function over 60 lines | SwiftLint `function_body_length` |
| No type body over 250 lines | SwiftLint `type_body_length` |
| Every public type/function has documentation comment | SwiftLint `missing_docs` |

### Skill compliance

The codebase must pass these custom skills described in the user's CLAUDE.md:

- `/simplify`: every file passes. Run at end of each phase.
- `/clean-and-refactor`: every package passes. Run at end of each phase.
- `/tech-debt-audit`: every major component (each package, each Features folder, the build pipeline) passes. Run at end of every phase and before final delivery.

## Section 13: Phased build plan

Each phase ends with a hard Acceptance Gate. Do not proceed past a gate that doesn't pass.

### Phase 0: Conventions extraction (no SyncBar code yet)

Tasks:
- [ ] Locate MailNotifier, MeetingNotifier, LinearBar repos
- [ ] Read each repo end-to-end
- [ ] Write `/tasks/conventions.md` per Section 2
- [ ] Write a Phase 1 plan in plan mode and present for confirmation

Acceptance gate:
- [ ] `/tasks/conventions.md` is complete and covers every bullet in Section 2
- [ ] Human (or self-check) confirms the conventions extraction looks right
- [ ] Phase 1 plan is documented in `/tasks/todo.md` status section

### Phase 1: Foundation

Tasks:
- [ ] Bootstrap repo following MailNotifier's structure
- [ ] Set up build pipeline mirroring MailNotifier
- [ ] Set up GitHub Actions mirroring MailNotifier
- [ ] Set up SwiftLint, SwiftFormat configs from MailNotifier
- [ ] Configure entitlements (sandbox, iCloud, network, Keychain Sharing if applicable)
- [ ] Create CloudKit container in dev environment
- [ ] Initialize empty `App/` with SyncBarApp.swift, AppDelegate.swift, scene setup
- [ ] Set up `.accessory` activation policy (no Dock icon)
- [ ] Create the status item with placeholder icon
- [ ] Stub each Package: `RemarkableKit`, `NotionKit`, `OcrKit`, `RulesEngine`, `SyncCore`, `LedgerKit`, `KeychainKit`, `DesignSystem`
- [ ] Each Package has its own `README.md` and `Tests/` folder with one passing smoke test
- [ ] Pre-commit hooks installed (lint, format)
- [ ] `make bootstrap`, `make build`, `make test`, `make lint`, `make format` all work

Acceptance gate:
- [ ] App launches as a menu bar app. Status item appears. Nothing else.
- [ ] `make test` runs and passes
- [ ] `make lint` and `make format` clean
- [ ] CI green on a draft PR
- [ ] `/simplify`, `/clean-and-refactor`, `/tech-debt-audit` pass

### Phase 2: KeychainKit, LedgerKit, settings infrastructure

Tasks:
- [ ] Write `KeychainKit` with iCloud synchronizable items, typed accessors, full unit tests
- [ ] Write `LedgerKit` with CloudKit private DB integration, full record type definitions, unit tests against InMemoryLedger, integration tests against local CloudKit
- [ ] Add `SettingsService` (part of LedgerKit) that wraps `AppSettings` record with defaults
- [ ] Wire launch-at-startup using `SMAppService` (toggled by `AppSettings.launchAtStartup`)
- [ ] Initial `AppSettings` record created on first launch with defaults

Acceptance gate:
- [ ] Keychain round-trip tests pass
- [ ] CloudKit record CRUD tests pass for every record type
- [ ] First-launch creates `AppSettings` singleton; relaunch reads it
- [ ] Toggling launch-at-startup updates `SMAppService` registration
- [ ] `/simplify`, `/clean-and-refactor`, `/tech-debt-audit` pass

### Phase 3: Main window and sidebar shell

Tasks:
- [ ] Implement main window with three-region layout (sidebar, notebook list area, rules sheet area)
- [ ] Sidebar shows reMarkable section (with "Not connected" state), Notion accounts list (empty), "Add Notion workspace" button, divider, "Sync log" and "Settings" nav items
- [ ] Settings window scaffolded with five tabs (General, OCR, Accounts, Data, Advanced), each empty
- [ ] Menu bar dropdown matches Section 8 (Sync now, Open, Pause, Settings, Quit)
- [ ] Snapshot tests for main window empty state (light + dark)

Acceptance gate:
- [ ] App opens, shows main window with empty sidebar and empty notebook list
- [ ] Menu bar dropdown renders and "Quit" works
- [ ] Snapshot tests pass
- [ ] `/simplify`, `/clean-and-refactor`, `/tech-debt-audit` pass

### Phase 4: Notion connection

Tasks:
- [ ] Write `NotionKit` with full client (auth code exchange, list pages, list databases, get schema)
- [ ] OAuth flow: launch system browser to authorize URL, capture redirect via local loopback HTTP listener (or `ASWebAuthenticationSession` if MailNotifier uses it)
- [ ] On success, store token in iCloud Keychain, create `NotionAccount` record in CloudKit
- [ ] Sidebar reflects connected workspaces
- [ ] "Add Notion workspace" supports multiple workspaces (each launches a fresh OAuth)
- [ ] Disconnect button in Settings → Accounts
- [ ] Integration tests for OAuth roundtrip (mocked Notion)

Acceptance gate:
- [ ] User can connect a Notion workspace (mocked or real); sidebar updates
- [ ] Adding a second workspace works without collision
- [ ] Disconnecting removes the workspace and its Keychain entry
- [ ] All Phase 4 tests pass
- [ ] `/simplify`, `/clean-and-refactor`, `/tech-debt-audit` pass

### Phase 5: reMarkable connection (pre-pair tolerant)

Tasks:
- [ ] Write `RemarkableKit` with auth + catalog methods, fixtures
- [ ] Onboarding flow: welcome → connect reMarkable (with "I'll do this later") → connect Notion → done
- [ ] Sidebar reflects pre-paired or connected state
- [ ] When connected, fetch notebook list; populate the center pane
- [ ] Notebook list refreshes on app launch and Settings window close
- [ ] Settings → Accounts shows reMarkable status with re-pair / disconnect controls
- [ ] Integration tests with mocked reMarkable responses

Acceptance gate:
- [ ] Pre-pair flow works end to end (skip pairing, continue to Notion)
- [ ] Mocked pairing flow works (one-time code → both tokens stored → notebooks fetched)
- [ ] Notebook list renders with at least 3 sample notebooks from fixtures
- [ ] Refresh on Settings close verified
- [ ] `/simplify`, `/clean-and-refactor`, `/tech-debt-audit` pass

### Phase 6: Rules sheet

Tasks:
- [ ] Implement Rules sheet UI per Section 8
- [ ] Notion destination picker that lazy-loads pages and databases
- [ ] Database schema fetch on database selection
- [ ] Per-property mapping UI dynamically built from schema
- [ ] Save creates a `Rule` record; update modifies it
- [ ] Disable/delete flows
- [ ] Snapshot tests for sheet in multiple states (page, database with various property types)

Acceptance gate:
- [ ] User can create a rule with a page destination, save, see it persist after relaunch
- [ ] User can create a rule with a database destination, configure property mappings, save
- [ ] Disabling a rule is reflected in sidebar status badge
- [ ] Deleting a rule removes it from CloudKit
- [ ] `/simplify`, `/clean-and-refactor`, `/tech-debt-audit` pass

### Phase 7: RulesEngine

Tasks:
- [ ] Implement `RulesEngine.evaluate(...)` per Section 7
- [ ] Exhaustive unit tests: every title strategy, every OCR mode, every property type, every directive outcome
- [ ] Tests cover: new page, modified page, unchanged page, orphan, title fallback when OCR empty, property mapping when schema mismatched (returns RuleValidationError-style directive)

Acceptance gate:
- [ ] Coverage on RulesEngine ≥ 95%
- [ ] All edge cases covered by name in test file
- [ ] `/simplify`, `/clean-and-refactor`, `/tech-debt-audit` pass

### Phase 8: OcrKit

Tasks:
- [ ] Implement `VisionOcrProvider` using `VNRecognizeTextRequest` with `revision` set to latest stable, `recognitionLevel = .accurate`, language correction on
- [ ] Implement `OpenAIOcrProvider` against the documented chat-completions vision endpoint
- [ ] Implement `AnthropicOcrProvider` against the documented messages API with image content
- [ ] `OcrProviderFactory.make(...)` chooses based on `AppSettings.ocrProvider`, fetches API key from KeychainKit if needed
- [ ] Unit tests with stub images and recorded responses
- [ ] "Test connection" buttons in Settings → OCR that call the provider with a known sample image

Acceptance gate:
- [ ] Vision provider transcribes a sample handwritten page in test fixture above 85% Levenshtein match
- [ ] OpenAI and Anthropic providers return correctly parsed `OcrResult` from mocked HTTP responses
- [ ] Test connection button works for each provider
- [ ] `/simplify`, `/clean-and-refactor`, `/tech-debt-audit` pass

### Phase 9: Sync engine

Tasks:
- [ ] Implement `SyncCoordinator` per Section 7
- [ ] Sync cycle implementation per Section 5 flow chart
- [ ] PDF rasterization helper (use PDFKit's `pageImage(at:size:)`)
- [ ] PDF download cached per cycle (avoid redundant downloads when notebook has multiple changed pages)
- [ ] Notion page creation (with optional PDF attachment as a file block)
- [ ] Notion page update (replace title, replace blocks)
- [ ] Orphan detection
- [ ] SyncEvent recording for every action
- [ ] "Sync now" menu bar action triggers immediate cycle
- [ ] Background timer per `AppSettings.syncIntervalSeconds`
- [ ] Pause/resume from menu bar
- [ ] Notifications on sync failure (using `UserNotifications` framework), gated by setting

Acceptance gate:
- [ ] Mocked happy path: 3-page notebook syncs to mocked Notion, all 3 SyncedPage and SyncEvent records exist
- [ ] Idempotency: second run causes 0 Notion writes, 0 new SyncedPage records, but does record "rule_run_completed" SyncEvent
- [ ] Modified page: bumping version hash triggers one update call
- [ ] Orphan: removed page marked orphaned without deleting Notion side
- [ ] Timer respects configured interval; changing interval reschedules without restart
- [ ] Pause/resume works from menu bar dropdown
- [ ] Notification fires on injected failure
- [ ] `/simplify`, `/clean-and-refactor`, `/tech-debt-audit` pass

### Phase 10: Sync log

Tasks:
- [ ] Sync log view per Section 8
- [ ] Filters: rule, event type, date range
- [ ] Click-through to Notion URLs opens default browser
- [ ] "Clear log" with confirm
- [ ] Snapshot tests for log states (empty, populated, all-failures, mixed)

Acceptance gate:
- [ ] Log renders after a sync cycle with correct event rows
- [ ] All filters work
- [ ] Clear log empties SyncEvent records and refreshes the view
- [ ] `/simplify`, `/clean-and-refactor`, `/tech-debt-audit` pass

### Phase 11: Settings polish and export

Tasks:
- [ ] Settings → General complete (interval, launch, appearance, notifications)
- [ ] Settings → OCR complete (provider, key fields, test connection)
- [ ] Settings → Accounts complete (reMarkable, Notion workspaces)
- [ ] Settings → Data: "Export ledger as JSON" save panel writes a complete snapshot
- [ ] Settings → Data: "Erase local cache" clears any local caches; preserves CloudKit
- [ ] Settings → Advanced (log verbosity, open log folder, reset to defaults)
- [ ] Closing Settings window triggers notebook refresh
- [ ] Snapshot tests for every Settings tab

Acceptance gate:
- [ ] Export produces a valid JSON file with every record type present
- [ ] Erase local cache leaves CloudKit data intact (verified via reopen)
- [ ] Reset to defaults restores `AppSettings` to initial values
- [ ] `/simplify`, `/clean-and-refactor`, `/tech-debt-audit` pass

### Phase 12: Release readiness

Tasks:
- [ ] Sparkle appcast configured
- [ ] Code signing config in place; `make release` produces a signed, notarized DMG
- [ ] Sparkle EdDSA signatures generated for the build
- [ ] CHANGELOG.md with 0.1.0 entry
- [ ] README final pass with: what this is, prerequisites (Apple ID with iCloud, Notion account, optional API key), install instructions, first-run walkthrough, reMarkable pairing-day instructions, privacy statement (no data leaves your machine except to reMarkable, Notion, and your chosen OCR provider; ledger lives in your iCloud)
- [ ] ARCHITECTURE.md with diagrams (text or ASCII)
- [ ] SECURITY.md with threat model and incident contact
- [ ] CONTRIBUTING.md with TDD discipline and skill compliance reminders
- [ ] Final `/tech-debt-audit` pass over every package

Acceptance gate:
- [ ] `make release` produces a DMG that installs and runs on a clean macOS user account
- [ ] App passes all CI jobs
- [ ] All audits pass
- [ ] README contains everything the user needs to do in the morning

## Section 14: Morning checklist for the human

When the user wakes up, the following must work:

1. `git pull`
2. `make bootstrap`
3. `make build`
4. `make run` (or open Finder, open the built app)
5. App launches as menu bar item, shows main window
6. Complete onboarding using "I'll connect reMarkable later" path
7. Connect a Notion workspace using real OAuth (will require Notion integration credentials, see below)
8. Save a draft rule (will be disabled because no notebooks yet)
9. Open Settings, verify all tabs render

What the user must do themselves:

1. Create a Notion internal integration at notion.so/my-integrations, copy client ID and secret
2. Put Notion client ID and secret in `~/.syncbar/notion.json` (path documented in README), or however the conventions file says to handle local app secrets that aren't user-facing
3. When reMarkable arrives:
   - Sign in to my.remarkable.com
   - Generate a one-time pairing code
   - Open SyncBar, click "Connect reMarkable" in sidebar, enter code
   - Wait for notebooks to populate
   - Enable the draft rule

This checklist must be in the README under "Day of pairing".

## Section 15: Things the agent must NOT silently decide

If any of the following arise, stop and write to `/tasks/lessons.md`. Do not silently choose.

- MailNotifier's conventions conflict with what this spec describes for functionality, in a way that materially affects user experience
- reMarkable cloud API returns shapes that don't match recorded fixtures
- CloudKit schema requires changes that would invalidate existing user data after release (this is a release-blocking concern; v1 has no existing users, but the agent should still document the schema with versioning in mind)
- Sparkle EdDSA keys cannot be located on the release machine (the agent shouldn't generate new ones without confirmation; that would break upgrade paths for other apps if keys are shared)
- An external dependency cannot be resolved in the version range MailNotifier uses
- Vision framework produces output that materially deviates from the contract (e.g., returns non-text artifacts)

## Section 16: Definition of done

The build is "done" when:

1. Every checkbox in every Acceptance Gate is checked.
2. `make bootstrap && make lint && make test && make ui-test && make build && make release` all run green on a clean machine.
3. All three skills pass on entire codebase: `/simplify`, `/clean-and-refactor`, `/tech-debt-audit`.
4. README, ARCHITECTURE, SECURITY, CONTRIBUTING, CHANGELOG complete.
5. `/tasks/lessons.md` summarizes any deviations from this spec with rationale.
6. `/tasks/conventions.md` accurately reflects MailNotifier conventions used.
7. A final summary is written at the bottom of this file documenting what was built and any items deferred.

## Review

(To be filled in by the agent at end of build.)
