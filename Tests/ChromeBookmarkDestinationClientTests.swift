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

    func test_refuses_to_write_file_while_chrome_running() async throws {
        let file = try writeChromeFixture()
        defer { try? FileManager.default.removeItem(at: file) }
        let client = ChromeBookmarkDestinationClient(bookmarksURLOverride: file, chromeRunningOverride: true)

        do {
            _ = try await client.write(payload: payload("https://a.com", title: "A"),
                                       configuration: config(["Bookmarks Bar"]), existingExternalId: nil)
            XCTFail("expected a throw while Chrome is running (B3 has no live path yet)")
        } catch {
            // Expected: the JSON path refuses to write under a running Chrome.
        }
    }
}
