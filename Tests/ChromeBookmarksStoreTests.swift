//
//  ChromeBookmarksStoreTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
import CryptoKit
@testable import SyncBar

final class ChromeBookmarksStoreTests: XCTestCase {

    private func fixtureData(includeBarBookmark: Bool = true) -> Data {
        var barChildren: [[String: Any]] = []
        if includeBarBookmark {
            barChildren.append(["type": "url", "name": "Existing", "url": "https://existing.com",
                                "id": "5", "guid": "guid-existing", "date_added": "13350000000000000"])
        }
        let root: [String: Any] = [
            "version": 1,
            "checksum": "stale",
            "roots": [
                "bookmark_bar": ["type": "folder", "name": "Bookmarks bar", "id": "1", "children": barChildren],
                "other": ["type": "folder", "name": "Other bookmarks", "id": "2", "children": []],
                "synced": ["type": "folder", "name": "Mobile bookmarks", "id": "3", "children": []]
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    /// Locks the checksum algorithm: it must equal an explicitly-built MD5 over
    /// Chromium's documented byte order (id + name[UTF-16LE] + "url"/"folder" + …).
    func test_checksum_matches_explicit_byte_construction() {
        let roots: NSDictionary = [
            "bookmark_bar": ["type": "folder", "name": "Bookmarks bar", "id": "1",
                             "children": [["type": "url", "name": "Hi", "url": "https://x.com", "id": "5"]]],
            "other": ["type": "folder", "name": "Other", "id": "2", "children": []],
            "synced": ["type": "folder", "name": "Mobile", "id": "3", "children": []]
        ]
        func utf16le(_ s: String) -> Data {
            var d = Data()
            for u in s.utf16 { d.append(UInt8(u & 0xff)); d.append(UInt8(u >> 8)) }
            return d
        }
        var expected = Data()
        expected += Data("1".utf8); expected += utf16le("Bookmarks bar"); expected += Data("folder".utf8)
        expected += Data("5".utf8); expected += utf16le("Hi"); expected += Data("url".utf8); expected += Data("https://x.com".utf8)
        expected += Data("2".utf8); expected += utf16le("Other"); expected += Data("folder".utf8)
        expected += Data("3".utf8); expected += utf16le("Mobile"); expected += Data("folder".utf8)
        let expectedHex = Insecure.MD5.hash(data: expected).map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(ChromeBookmarksStore.checksum(roots: roots), expectedHex)
    }

    func test_add_bookmark_appends_and_is_findable() throws {
        let store = try ChromeBookmarksStore(data: fixtureData(includeBarBookmark: false))
        XCTAssertNil(store.guid(forURL: "https://new.com", inFolderPath: ["Bookmarks Bar"]))
        let guid = try store.addBookmark(name: "New", url: "https://new.com", folderPath: ["Bookmarks Bar"])
        XCTAssertFalse(guid.isEmpty)
        XCTAssertEqual(store.guid(forURL: "https://new.com", inFolderPath: ["Bookmarks Bar"]), guid)
    }

    func test_add_creates_nested_folder_path() throws {
        let store = try ChromeBookmarksStore(data: fixtureData(includeBarBookmark: false))
        _ = try store.addBookmark(name: "Nested", url: "https://nested.com", folderPath: ["Bookmarks Bar", "From Safari"])
        XCTAssertNotNil(store.guid(forURL: "https://nested.com", inFolderPath: ["Bookmarks Bar", "From Safari"]))
    }

    func test_serialized_round_trips_and_recomputes_checksum() throws {
        let store = try ChromeBookmarksStore(data: fixtureData())
        _ = try store.addBookmark(name: "New", url: "https://new.com", folderPath: ["Bookmarks Bar"])
        let data = try store.serialized()

        let reparsed = try ChromeBookmarksStore(data: data)
        XCTAssertNotNil(reparsed.guid(forURL: "https://new.com", inFolderPath: ["Bookmarks Bar"]))
        XCTAssertNotNil(reparsed.guid(forURL: "https://existing.com", inFolderPath: ["Bookmarks Bar"]),
                        "existing bookmarks are preserved")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotEqual(obj?["checksum"] as? String, "stale", "checksum is recomputed on serialize")
    }
}
