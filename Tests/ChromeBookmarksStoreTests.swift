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

    func test_mirror_updates_adds_deletes_and_prunes_within_managed_roots() throws {
        let root: [String: Any] = [
            "version": 1, "checksum": "x",
            "roots": [
                "bookmark_bar": ["type": "folder", "name": "Bookmarks bar", "id": "1", "children": [
                    ["type": "url", "name": "Apple OLD", "url": "https://apple.com", "id": "5", "guid": "g5"],
                    ["type": "url", "name": "Stale", "url": "https://stale.com", "id": "6", "guid": "g6"],
                    ["type": "folder", "name": "Old", "id": "7", "children": [
                        ["type": "url", "name": "X", "url": "https://x.com", "id": "8", "guid": "g8"]
                    ]]
                ]],
                // A Chrome-native bookmark in a root NOT referenced by desired must be left alone.
                "other": ["type": "folder", "name": "Other", "id": "2", "children": [
                    ["type": "url", "name": "Keep me", "url": "https://keep.com", "id": "9", "guid": "g9"]
                ]],
                "synced": ["type": "folder", "name": "Mobile", "id": "3", "children": []]
            ]
        ]
        let store = try ChromeBookmarksStore(data: try JSONSerialization.data(withJSONObject: root))

        let desired: [(path: [String], url: String, title: String)] = [
            (["Bookmarks Bar"], "https://apple.com", "Apple"),                 // update title
            (["Bookmarks Bar"], "https://new.com", "New"),                     // add
            (["Bookmarks Bar", "Supabase"], "https://supabase.com", "Supabase") // add + create folder
        ]
        let counts = store.mirror(desired: desired)

        XCTAssertEqual(counts.updated, 1, "Apple title")
        XCTAssertEqual(counts.added, 2, "New + Supabase")
        XCTAssertEqual(counts.deleted, 2, "Stale + Old/X")

        XCTAssertEqual(store.guid(forURL: "https://apple.com", inFolderPath: ["Bookmarks Bar"]), "g5",
                       "matched bookmark keeps its guid (title updated in place)")
        XCTAssertNil(store.guid(forURL: "https://stale.com", inFolderPath: ["Bookmarks Bar"]))
        XCTAssertNil(store.guid(forURL: "https://x.com", inFolderPath: ["Bookmarks Bar", "Old"]), "emptied folder pruned")
        XCTAssertNotNil(store.guid(forURL: "https://new.com", inFolderPath: ["Bookmarks Bar"]))
        XCTAssertNotNil(store.guid(forURL: "https://supabase.com", inFolderPath: ["Bookmarks Bar", "Supabase"]))
        // The "other" root wasn't in desired → its native bookmark is untouched.
        XCTAssertEqual(store.guid(forURL: "https://keep.com", inFolderPath: ["Other"]), "g9")
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
