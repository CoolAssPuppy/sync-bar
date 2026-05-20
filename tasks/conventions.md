# Conventions inherited from mail-notifier

Captured during the overnight build. Source of truth for SyncBar' layout, build, signing, theming, and view choices.

## Project layout

- Flat single-target Xcode project, generated from `project.yml` via XcodeGen.
- Source under `Source/{App,Models,Services,Utilities,Views,Views/Components}/`.
- Resources at the repository root (`Info.plist`, `SyncBar.entitlements`, `Images.xcassets/`).
- Build scripts under `scripts/` plus a thin `Makefile` aliasing them.
- `tasks/` holds plan, lessons, and conventions for the overnight build.

mail-notifier and linear-bar each use this same flat layout; meeting-notifier is more nested and less polished, so we don't follow it.

## Build pipeline

- XcodeGen at `project.yml`. The generated `.xcodeproj` is gitignored.
- Debug builds force `MERGED_BINARY_TYPE: manual` and `MERGEABLE_LIBRARY: NO` to avoid the Xcode 15+ mergeable-library / XCTest interaction.
- Release builds enable hardened runtime; Debug builds disable it (XCTest runtime injection breaks otherwise).
- All targets sign with team `955GSY56UT` (Strategic Nerds).
- The `Makefile` exposes `bootstrap`, `build`, `release`, `run`, `test`, `clean`.

## Code signing and notarization

mail-notifier uses Developer ID Application "Prashant Sridharan (955GSY56UT)", notarytool with the `agent-server` Keychain profile, and DMG packaging via `create-dmg`. SyncBar will reuse the same identity and profile when the release script lands in 0.2.

## Sparkle

mail-notifier hosts its appcast at `https://coolasspuppy.com/mail-notifier-updates`. SyncBar advertises `https://coolasspuppy.com/syncbar-updates` (not yet pointed at a real R2 bucket). The Sparkle public Ed25519 key is shared across all Strategic Nerds apps.

## Versioning

`MARKETING_VERSION` (`x.y.z`) plus integer `CURRENT_PROJECT_VERSION` in `project.yml`. SyncBar starts at `0.1.0` build `1`.

## Theming

10-theme palette ported verbatim from mail-notifier (`System`, `Hoth`, `Risa`, `Weasley`, `Starbuck`, `Cylon`, `Vader`, `Kirk`, `Hermione`, `Nerds`). `ThemeStore.shared` publishes the active palette and observes `effectiveAppearance`. Views read `\.theme` from the SwiftUI environment.

SyncBar defaults to the `Nerds` theme (yellow primary on dark) so first impression matches the Strategic Nerds brand. mail-notifier defaults to `system`. Either is consistent — choose to make SyncBar feel like a Strategic Nerds product immediately.

## View architecture

- SwiftUI first, AppKit for window management and `NSStatusItem` only.
- `AppDelegate` (`@MainActor`, `NSApplicationDelegate`) owns the status item, popover, main window, and the `SyncCoordinator`.
- `NSApp.setActivationPolicy(.accessory)` — no Dock icon.
- Main window is constructed by hand in code: 1040×680, fullSizeContentView, titlebarAppearsTransparent, dark appearance.
- Popovers use `NSPopover` with `.transient` behavior and a global event monitor for dismissal.

## State management

- `ObservableObject` + `@Published` for stores.
- `Ledger.shared` for persistent state, `AppSettings.shared` for prefs, `ThemeStore.shared` for theming.
- Views use `@ObservedObject` for shared stores and `@State` for local UI state.

## Async

- `async/await` for new code (linear-bar pattern).
- `Combine` for `NotificationCenter.default.publisher(for:)` plumbing inside the AppDelegate.

## Persistence

- v0.1: `UserDefaults` everywhere, JSON-encoded values for collections.
- v0.2: CloudKit private database via the same `Ledger` API.
- Tokens always in iCloud Keychain via `KeychainAccess` (synchronizable, `afterFirstUnlock`).

## Logging

- `os.Logger` via a single `Log` enum exposing categorized loggers: `app`, `sync`, `notion`, `remarkable`, `ocr`, `ledger`, `ui`.
- Subsystem: `com.strategicnerds.SyncBar`.

## Testing layout

- `Tests/` next to `Source/`. One XCTest target (`SyncBarTests`).
- v0.1 ships `RulesEngineTests.swift`. Expand coverage in 0.2.

## SwiftLint / SwiftFormat

mail-notifier has no `.swiftlint.yml`; linear-bar does. v0.1 ships without one; we'll port linear-bar's config in 0.2 once code is stable enough to benefit from the strictness.

## GitHub Actions CI

mail-notifier doesn't ship CI workflows. We follow that convention — release is a single `scripts/release.sh` invoked manually. CI is a 0.2 task.

## Menu bar patterns

- `NSStatusItem.variableLength`.
- Template SF Symbol image (`arrow.triangle.2.circlepath`).
- Right-click vs left-click handled via `event.type == .rightMouseUp`; right opens a small `NSMenu`, left toggles the popover.
- Rotating CALayer transform on the status item button while a sync is running.

## Launch at login

mail-notifier has no toggle; linear-bar uses `LaunchAtLogin-Modern`. v0.1 ships a Settings toggle wired to a UserDefault for now; SMAppService registration moves into `LaunchAtLoginManager` (matching linear-bar) in 0.2.

## Bundle identifier / deployment target

- App: `com.strategicnerds.SyncBar`.
- Test bundle: `com.strategicnerds.SyncBarTests`.
- macOS deployment target: 14.0.
- Swift: 5.9.
