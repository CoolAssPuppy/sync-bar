//
//  UXStateRenderTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  End-to-end render of the real menu bar popover and Syncs screen in each sync
//  state (paused, idle with failures, syncing). Runs offscreen against the
//  isolated test ledger and demo data, so it never touches the user's screen
//  or data. Writes PNGs when UX_SHOTS_DIR is set (scripts/ux-shots.sh sets it)
//  and checks the overview each surface shows.
//

import AppKit
import SwiftUI
import XCTest
@testable import SyncBar

@MainActor
final class UXStateRenderTests: XCTestCase {

    private var outputDir: URL? {
        ProcessInfo.processInfo.environment["UX_SHOTS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    override func tearDown() async throws {
        AppSettings.shared.pauseSyncing = false
        Ledger.shared.setDemoMode(false)
    }

    func test_paused_and_failed_states_render_and_say_what_they_are() throws {
        let ledger = Ledger.shared
        ledger.setDemoMode(true)
        let tasks = TaskSyncCoordinator(ledger: ledger)
        let coordinator = SyncCoordinator(ledger: ledger, remarkable: MockRemarkableClient(), taskSyncs: tasks)

        AppSettings.shared.pauseSyncing = true
        let paused = SyncOverview.current(coordinator: coordinator, taskCoordinator: tasks)
        XCTAssertTrue(paused.isPaused)
        XCTAssertEqual(paused.headline, "Paused")
        try render(coordinator, tasks, name: "1-paused")

        AppSettings.shared.pauseSyncing = false
        let failed = SyncOverview.current(coordinator: coordinator, taskCoordinator: tasks)
        XCTAssertFalse(failed.isPaused)
        XCTAssertEqual(failed.headline, "1 sync failed", "demo data has one failed sync")
        try render(coordinator, tasks, name: "2-idle-with-failure")

        // The failed Google sync's account card says why and offers Reconnect;
        // "View log" lands on Activity searched and filtered to its failures.
        guard let outputDir else { return }
        let theme = ThemeStore.shared.palette
        try snapshot(ConnectionsView().environment(\.theme, theme), size: CGSize(width: 860, height: 760),
                     to: outputDir.appendingPathComponent("4-connections-with-failure.png"))
        let activity = ActivityView(search: .constant("Customer interviews"),
                                    selectedEventType: .constant(SyncEventType.pageFailed.rawValue))
        try snapshot(activity.environment(\.theme, theme), size: CGSize(width: 860, height: 520),
                     to: outputDir.appendingPathComponent("5-activity-failures-for-one-sync.png"))
        let noMatch = ActivityView(search: .constant("nothing matches this"), selectedEventType: .constant("all"))
        try snapshot(noMatch.environment(\.theme, theme), size: CGSize(width: 860, height: 420),
                     to: outputDir.appendingPathComponent("6-activity-no-match.png"))
    }

    func test_syncing_state_renders_while_a_run_is_in_flight() async throws {
        let ledger = Ledger.shared
        // Other tests leave rules in the shared test store; render only ours.
        let leftovers = ledger.rules
        leftovers.forEach { ledger.deleteRule(id: $0.id) }
        defer { leftovers.forEach { ledger.upsertRule($0) } }
        let gate = HoldingSource()
        var rule = SyncRule(source: .safari(SafariSourceConfig(folderId: "all", folderName: "UX bookmarks")))
        rule.destinations = [DestinationBinding(configuration:
            .chrome(ChromeDestinationConfig(profileDirName: "Default", targetFolderPath: ["UX test"])))]
        ledger.upsertRule(rule)
        defer { ledger.deleteRule(id: rule.id) }

        let tasks = TaskSyncCoordinator(ledger: ledger)
        let coordinator = SyncCoordinator(
            ledger: ledger, remarkable: MockRemarkableClient(),
            sourceClient: { _ in gate }, destinationClient: { _ in NullDestination() },
            entitlementForSource: { _ in true }, readBudgetExhausted: { false }, taskSyncs: tasks)

        coordinator.syncNow(ruleId: rule.id)
        let deadline = Date().addingTimeInterval(5)
        while !coordinator.isSyncing && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(coordinator.isSyncing)
        XCTAssertEqual(SyncOverview.current(coordinator: coordinator, taskCoordinator: tasks).headline, "Syncing…")
        try render(coordinator, tasks, name: "3-syncing")

        gate.release()
        while coordinator.isSyncing && Date() < deadline.addingTimeInterval(5) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(coordinator.isSyncing)
    }

    // MARK: Rendering

    private func render(_ coordinator: SyncCoordinator, _ tasks: TaskSyncCoordinator, name: String) throws {
        guard let outputDir else { return }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let theme = ThemeStore.shared.palette
        let actions = MenuBarPopoverActions(syncNow: { _, _ in }, syncTask: { _ in }, openMainWindow: {},
                                            openSettings: {}, openNotionUrl: { _ in }, togglePause: {},
                                            uploadFiles: {}, quit: {})
        let popover = MenuBarPopover(coordinator: coordinator, taskCoordinator: tasks, actions: actions)
        try snapshot(popover, size: CGSize(width: 380, height: 520), to: outputDir.appendingPathComponent("\(name)-popover.png"))

        let home = SyncsHomeView(coordinator: coordinator, taskCoordinator: tasks,
                                 onNew: {}, onEdit: { _ in }, onEditTask: { _ in })
            .environment(\.theme, theme)
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
        try snapshot(home, size: CGSize(width: 860, height: 620), to: outputDir.appendingPathComponent("\(name)-syncs.png"))
    }

    private func snapshot<V: View>(_ view: V, size: CGSize, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return XCTFail("could not make a bitmap for \(url.lastPathComponent)")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("could not encode \(url.lastPathComponent)")
        }
        try png.write(to: url)
    }
}

// MARK: - Doubles

/// A source whose listing waits until released, so a run stays in flight.
private final class HoldingSource: SourceClient, @unchecked Sendable {
    let kind: SourceKind = .safari
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func listScopes() async throws -> [SourceScope] { [] }
    func listItems(config: SourceConfiguration) async throws -> [SourceItem] {
        if !released { await withCheckedContinuation { continuation = $0 } }
        return []
    }
    func content(for item: SourceItem, config: SourceConfiguration) async throws -> NoteContent {
        NoteContent(blocks: [])
    }
    func resolveTitle(for item: SourceItem, content: NoteContent,
                      config: SourceConfiguration, strategyOverride: TitleStrategy?) -> String { item.name }
    func shouldSkipAsEmpty(content: NoteContent, config: SourceConfiguration, ocrModeOverride: OcrMode?) -> Bool { false }
}

private struct NullDestination: DestinationClient {
    let kind: DestinationKind = .chrome
    func write(payload: DestinationPayload, configuration: DestinationConfiguration,
               existingExternalId: String?) async throws -> DestinationWriteResult {
        DestinationWriteResult(externalId: "null", externalURL: nil, notes: nil)
    }
}
