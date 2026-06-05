//
//  ChromeBookmarkDestinationClientTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

final class ChromeBookmarkDestinationClientTests: XCTestCase {

    private func writeChromeFixture() throws -> URL {
        let root: [String: Any] = [
            "version": 1,
            "checksum": "x",
            "roots": [
                "bookmark_bar": ["type": "folder", "name": "Bookmarks bar", "id": "1", "children": []],
                "other": ["type": "folder", "name": "Other bookmarks", "id": "2", "children": []],
                "synced": ["type": "folder", "name": "Mobile bookmarks", "id": "3", "children": []]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: root)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrome-bookmarks-\(UUID().uuidString).json")
        try data.write(to: url)
        return url
    }

    private func payload(_ urlString: String, title: String) -> DestinationPayload {
        DestinationPayload(title: title, body: "", sourceDate: .distantPast,
                           ruleNotebookName: title, pageNumber: 1, url: URL(string: urlString))
    }

    private func config(_ folderPath: [String]) -> DestinationConfiguration {
        .chrome(ChromeDestinationConfig(profileDirName: "Default", targetFolderPath: folderPath))
    }

    func test_writes_bookmark_into_target_folder_when_chrome_closed() async throws {
        let file = try writeChromeFixture()
        defer { try? FileManager.default.removeItem(at: file) }
        let client = ChromeBookmarkDestinationClient(bookmarksURLOverride: file, chromeRunningOverride: false)

        let result = try await client.write(payload: payload("https://a.com", title: "A"),
                                            configuration: config(["Bookmarks Bar", "From Safari"]),
                                            existingExternalId: nil)
        XCTAssertFalse(result.externalId?.isEmpty ?? true)

        let store = try ChromeBookmarksStore(data: try Data(contentsOf: file))
        XCTAssertNotNil(store.guid(forURL: "https://a.com", inFolderPath: ["Bookmarks Bar", "From Safari"]))
    }

    func test_payload_folder_path_mirrors_hierarchy_over_config_target() async throws {
        let file = try writeChromeFixture()
        defer { try? FileManager.default.removeItem(at: file) }
        let client = ChromeBookmarkDestinationClient(bookmarksURLOverride: file, chromeRunningOverride: false)

        // The item carries its own mirrored path; it must win over the config target.
        var payload = self.payload("https://s.com", title: "Supabase docs")
        payload.folderPath = ["Bookmarks Bar", "Supabase"]
        _ = try await client.write(payload: payload, configuration: config(["IGNORED"]), existingExternalId: nil)

        let store = try ChromeBookmarksStore(data: try Data(contentsOf: file))
        XCTAssertNotNil(store.guid(forURL: "https://s.com", inFolderPath: ["Bookmarks Bar", "Supabase"]))
        XCTAssertNil(store.guid(forURL: "https://s.com", inFolderPath: ["IGNORED"]))
    }

    func test_idempotent_second_write_creates_nothing() async throws {
        let file = try writeChromeFixture()
        defer { try? FileManager.default.removeItem(at: file) }
        let client = ChromeBookmarkDestinationClient(bookmarksURLOverride: file, chromeRunningOverride: false)

        let first = try await client.write(payload: payload("https://a.com", title: "A"),
                                           configuration: config(["Bookmarks Bar"]), existingExternalId: nil)
        let second = try await client.write(payload: payload("https://a.com", title: "A"),
                                            configuration: config(["Bookmarks Bar"]), existingExternalId: first.externalId)

        XCTAssertEqual(first.externalId, second.externalId)
        XCTAssertEqual(second.notes, "Already in Chrome")
    }

    func test_uses_applescript_path_when_chrome_running() async throws {
        let file = try writeChromeFixture()
        defer { try? FileManager.default.removeItem(at: file) }
        let box = ScriptBox()
        let client = ChromeBookmarkDestinationClient(
            bookmarksURLOverride: file,
            chromeRunningOverride: true,
            appleScriptRunner: { box.source = $0 }   // stub: never touch a real Chrome
        )

        let result = try await client.write(payload: payload("https://a.com", title: "Apple & Co"),
                                            configuration: config(["Bookmarks Bar", "From Safari"]),
                                            existingExternalId: nil)

        XCTAssertNotNil(result.externalId)
        let source = box.source ?? ""
        XCTAssertTrue(source.contains("Google Chrome"))
        XCTAssertTrue(source.contains("https://a.com"))
        XCTAssertTrue(source.contains("From Safari"))
        XCTAssertTrue(source.contains("\\\"") || source.contains("Apple & Co"), "title is embedded (and escaped)")
        // The file is NOT touched on the live path (no new node written by us).
        let store = try ChromeBookmarksStore(data: try Data(contentsOf: file))
        XCTAssertNil(store.guid(forURL: "https://a.com", inFolderPath: ["Bookmarks Bar", "From Safari"]))
    }

    // MARK: Reconcile (mirror)

    func test_reconcile_makes_chrome_match_safari_when_quit() async throws {
        // Chrome already has a stale bookmark in the bar that Safari doesn't have.
        let root: [String: Any] = [
            "version": 1, "checksum": "x",
            "roots": [
                "bookmark_bar": ["type": "folder", "name": "Bookmarks bar", "id": "1", "children": [
                    ["type": "url", "name": "Stale", "url": "https://stale.com", "id": "5", "guid": "g5"]
                ]],
                "other": ["type": "folder", "name": "Other", "id": "2", "children": []],
                "synced": ["type": "folder", "name": "Mobile", "id": "3", "children": []]
            ]
        ]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-rec-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: root).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let client = ChromeBookmarkDestinationClient(bookmarksURLOverride: file, chromeRunningOverride: false)
        let cfg = DestinationConfiguration.chrome(ChromeDestinationConfig(
            profileDirName: "Default", targetFolderPath: ["Bookmarks Bar"], mirrorExactly: true))
        XCTAssertTrue(client.reconciles(cfg))

        var keep = payload("https://a.com", title: "A")
        keep.folderPath = ["Bookmarks Bar"]
        let result = try await client.reconcile(desired: [keep], configuration: cfg)

        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.deleted, 1, "the stale bookmark not in Safari is removed")

        let store = try ChromeBookmarksStore(data: try Data(contentsOf: file))
        XCTAssertNotNil(store.guid(forURL: "https://a.com", inFolderPath: ["Bookmarks Bar"]))
        XCTAssertNil(store.guid(forURL: "https://stale.com", inFolderPath: ["Bookmarks Bar"]))
    }

    func test_reconcile_refuses_when_chrome_running() async throws {
        let file = try writeChromeFixture()
        defer { try? FileManager.default.removeItem(at: file) }
        let client = ChromeBookmarkDestinationClient(bookmarksURLOverride: file, chromeRunningOverride: true)
        let cfg = DestinationConfiguration.chrome(ChromeDestinationConfig(
            profileDirName: "Default", targetFolderPath: ["Bookmarks Bar"], mirrorExactly: true))
        do {
            _ = try await client.reconcile(desired: [], configuration: cfg)
            XCTFail("reconcile (with deletes) must refuse while Chrome is running")
        } catch { /* expected */ }
    }

    func test_default_config_does_not_reconcile() {
        let client = ChromeBookmarkDestinationClient()
        XCTAssertFalse(client.reconciles(config(["Bookmarks Bar"])), "mirror is off by default")
    }

    func test_applescript_source_finds_or_creates_nested_folders() {
        let source = ChromeBookmarkDestinationClient.appleScriptSource(
            title: "T", url: "https://t.com", folderPath: ["Other", "Imported", "Deep"])
        XCTAssertTrue(source.contains("other bookmarks"))
        XCTAssertTrue(source.contains("whose title is \"Imported\""))
        XCTAssertTrue(source.contains("whose title is \"Deep\""))
        XCTAssertTrue(source.contains("make new bookmark item"))
    }
}

/// Reference holder so the @Sendable AppleScript-runner stub can record the
/// generated source (write() awaits the runner before we read it).
private final class ScriptBox: @unchecked Sendable {
    var source: String?
}
