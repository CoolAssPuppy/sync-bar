# Adding a destination

Everything you must implement to add a new sync destination, derived from the
existing five (Notion, Linear, Google Docs, Apple Notes, Markdown). Work top to
bottom; the compiler will catch most omissions because the per-kind switches are
exhaustive.

## The model in three nouns

- **Source**: a reMarkable folder (`RmFolder`) and its documents (`RmFile`).
- **Destination**: a connected place notes can go, carrying a default config.
- **Connection**: a `SyncRule` (a source scope + shared note settings) holding
  `DestinationBinding`s (one per destination, each with the real config).

A destination has two halves: an **account/target record** (the connected place,
listed in the sidebar) and a **per-binding configuration** (how one folder writes
to it). Adding a destination means wiring both, plus the client that writes.

## Two kinds of destination

- **OAuth account** (Notion, Linear, Google Docs): connects through a browser
  flow, stores a token in the Keychain, and the account record carries identity
  (workspace/team/email). `requiresExternalAccount` is `true`.
- **Local target** (Markdown, Apple Notes): no sign-in. The "account" is just a
  marker row so the sidebar can list it. `requiresExternalAccount` is `false`.

Pick which one you are; it changes steps 5-6 and 10.

## Checklist

1. Brand asset
2. `DestinationKind` case + computed properties
3. Config payload + `DestinationConfiguration` case
4. Ledger storage (account/target array) + `defaultConfiguration`
5. Keychain key (if it stores a secret)
6. Auth: an `AuthService` (OAuth) or a marker (local)
7. `DestinationClient` (the write path) + `DestinationRouter`
8. Binding form (`XxxFormState` + `XxxForm` + `BindingEditorSheet`)
9. `AddDestinationSheet` (create flow)
10. Detail view wiring `DestinationDetailScaffold`
11. Sidebar + `MainView` routing
12. `RuleSheetView.configuredDestinations` (quick-add)
13. Tests

---

### 1. Brand asset

Add `Images.xcassets/Destinations/<Name>.imageset` (1x/2x/3x).

Gotcha: the mark must be a **transparent PNG** if you want it tinted. An opaque
PNG (no alpha) flattens to a solid square under `renderingMode(.template)`. Check
with `file *.png` (look for "RGBA", not "RGB"). If it is opaque, render it as-is
on a chip instead of tinting (see `NotebookListView.sourceIcon` for the reMarkable
mark, which does exactly this).

### 2. `DestinationKind` case + computed properties

In `Source/Models/Destinations.swift`, add a `DestinationKind` case and fill in
every computed property the compiler now demands: `label`, `sidebarSubtitle`,
`systemImage` (SF Symbol fallback), `assetName` (the imageset path),
`requiresExternalAccount`, `brandMarkIsMonochrome`. `DestinationKind` is
`CaseIterable`, so the new kind automatically appears in `AddDestinationSheet`'s
kind grid.

### 3. Config payload + `DestinationConfiguration` case

Add an `XxxDestinationConfig: Codable, Equatable, Hashable` struct with the
per-binding settings (e.g. `MarkdownFolderDestinationConfig` has `folderPath`,
`fileNameTemplate`, `includeFrontmatter`). Then add a `DestinationConfiguration`
case wrapping it, and handle it in `.kind` and `.summary` (the one-line label
shown in rule rows and the popover). See "Standard capabilities" for `accepts`.

### 4. Ledger storage + `defaultConfiguration`

In `Source/Models/Ledger.swift`, mirror an existing account/target type:
- a `@Published private(set) var xxx: [XxxRecord] = []`
- a storage key constant, and a line in `load()` and `flushPending()`
- `upsertXxx` / `removeXxx` (the remove takes a `bindingMatches` closure that
  cascades to bindings using this account; see `removeMarkdownTarget`)
- a field in the `exportSnapshot()` `Snapshot` struct
- the notification name in `broadcastChanged()`

Then add a `defaultConfiguration` accessor (an extension at the bottom of
`Destinations.swift`, like `NotionWorkspace.defaultConfiguration`) returning the
config a new connection inherits. Both connect flows (source-first and
destination-first) read this, so they never drift.

Note: storage is five parallel arrays today. That is the part that scales worst
per type; v0.3 deliberately left it un-unified. If the type count grows a lot,
collapse these into one kind-keyed store rather than adding a sixth array.

### 5. Keychain key (if it stores a secret)

Add a `KeychainStore.Key` case and its `account` string in
`Source/Services/KeychainStore.swift`. `KeychainStore` already does the
data-protection keychain + file-based fallback, so you get no access prompt on
signed builds for free.

### 6. Auth

- **OAuth**: add an `XxxAuthService` with `connect()` (opens the browser flow,
  exchanges the code, writes the token to the Keychain, returns the account
  record). Add an `AuthSecrets.isXxxConfigured` flag and the client id/secret
  plumbing (Doppler -> Secrets.xcconfig -> Info.plist; see the README). Follow
  Linear (custom-scheme `ASWebAuthenticationSession`) or Notion (loopback HTTP)
  depending on what the provider allows.
- **Local**: no auth. `AddDestinationSheet` creates a marker record directly.

### 7. `DestinationClient` (the write path)

Implement `XxxDestinationClient: DestinationClient` in
`Source/Services/Destinations/`, conforming to `write(payload:configuration:
existingExternalId:)`. Return a result carrying the external id and URL so the
ledger can update the same note in place next time (idempotency). Register it in
`DestinationRouter.client(for:)` (`Source/Services/DestinationClient.swift`).

### 8. Binding form

- Add `XxxFormState` in `Source/Views/BindingForms/BindingFormState.swift`.
- Add an `XxxForm` view (`Source/Views/BindingForms/XxxForm.swift`) editing it.
- Wire it into `BindingEditorSheet`: the `form` router case, the `init` that
  seeds state from an existing binding, `canSave`, and `save()` (builds the
  `DestinationConfiguration`). The sheet titles itself "Edit <label> Destination".

### 9. `AddDestinationSheet`

In `Source/Views/AddDestinationSheet.swift`: add the `detailsCard` case (the
fields/copy for this kind), and handle it in `primaryTitle`, `primaryIcon`,
`primaryAction`, `canSubmit`, and `submit()`/the connect flow. For a local target,
capture its default config here (the Markdown flow shows the folder picker and
stores the full default). For OAuth, call the `AuthService`.

### 10. Detail view

Add `XxxDetailView` (`Source/Views/DetailViews.swift`) that renders
`DestinationDetailScaffold` with:
- `title` / `subtitle` (from the account record)
- `activeBindings`: `ledger.bindings(matching:)` filtered to THIS account (match
  the config's identity, e.g. `workspaceId`/`accountEmail`/`folderPath`)
- `rename` (if the record has an editable name)
- `connectableFolders: ledger.folders` and `connectSource` (uses
  `defaultConfiguration`) for destination-first "Connect a folder"
- `reconnect` for OAuth accounts (re-runs `AuthService.connect()`); omit for
  local targets
- `disconnect` (calls the ledger remove)

### 11. Sidebar + `MainView` routing

- Add a `MainSelection` case (`Source/Views/MainView.swift`).
- In `Sidebar.swift`, `ForEach` the account/target array into `AccountRow`s with
  a tap that sets the selection.
- Add the `MainView.content` switch case routing the selection to `XxxDetailView`.

### 12. `RuleSheetView.configuredDestinations`

Add the destination to the quick-add list so a folder's rule sheet can attach it.
Use `defaultConfiguration` (the same accessor the detail-view connect uses).

### 13. Tests

- Add the kind to the Codable round-trip in `Tests/DestinationBindingTests.swift`.
- If it has any filtering/acceptance behavior, cover `accepts(...)`.
- Destinations are exercised end to end through `SyncCoordinatorTests` (the write
  path is an implementation detail tested via behavior).

---

## Standard capabilities every destination gets

- **Default-config inheritance**: a connection inherits `defaultConfiguration`
  and can override it per connection in `BindingEditorSheet`.
- **Idempotency**: the coordinator tracks `bindingId|fileId` -> versionHash and
  external id, so unchanged notes are skipped and changed ones update in place.
  Your client just needs to return the external id.
- **Source scope**: a rule may target the whole folder or hand-picked notebooks
  (`SyncRule.selectedFileIds`). This is resolved upstream; destinations are
  unaffected.
- **Reconnect**: OAuth accounts expose Reconnect in the detail gear drawer.
- **Tag filtering ("only sync tagged notes")**: see below.

### Tag filtering

Every destination supports "only sync tagged notes" through a per-binding filter,
so you get it for free; there is nothing to wire per kind. The pieces:
`DestinationBinding.requiredTags` (nil/empty means sync all) and
`DestinationBinding.accepts(fileTags:)`, which the coordinator calls to drop
notes lacking a required tag before OCR and before writing. The editor renders
the shared `RequiredTagsControl` for all kinds (step 8's "Filter" card), bound to
the binding's `requiredTags`.

Back-compat: filters saved before this was generalized lived on
`LinearDestinationConfig.requiredTags`. `DestinationBinding.effectiveRequiredTags`
falls back to that legacy field, so old Linear filters keep working with no
migration; new saves write the binding-level field and leave the legacy one nil.

## Handled generically (do not touch)

These already work off `DestinationKind`/`DestinationConfiguration`:
- icons everywhere (`DestinationIcon` via `assetName`)
- the sync log (`SyncLogView` keys off `SyncEventType`, not kind)
- the menu-bar popover, including the destination count badge
- the source/destination role badges in the detail headers
- the sync cycle itself (`SyncCoordinator`)

## Gotchas

- **Exhaustive switches**: adding a `DestinationKind` case makes the build fail at
  every switch you still need to handle (`label`, `summary`, the client factory,
  the editor router, etc.). That is your checklist. One `default:` exists in
  `AddDestinationSheet`, so double-check that file by hand.
- **Opaque brand PNGs** flatten under template tinting (see step 1).
- **Signing and the Keychain**: the command-line `make build` signs ad-hoc and
  has no `keychain-access-groups` entitlement, so OAuth tokens use the file-based
  fallback (and show the access prompt) in the dev loop. The data-protection
  keychain (no prompt) only takes effect in Xcode-run and Developer ID release
  builds. Verify token storage from a signed build, not `make run`.
- **Verify in the app, not just the build**: views and integrations are not
  covered by tests. Launch and look before shipping.
