//
//  SafariSourceClientTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

final class SafariSourceClientTests: XCTestCase {

    // MARK: Fixture

    /// A Safari-shaped bookmark tree: a Bookmarks Bar with two leaves and a
    /// "Dev" subfolder holding one leaf, plus a Reading List that must be ignored.
    private func writeFixture() throws -> URL {
        func leaf(_ uuid: String, _ title: String, _ url: String) -> [String: Any] {
            ["WebBookmarkType": "WebBookmarkTypeLeaf", "WebBookmarkUUID": uuid,
             "URLString": url, "URIDictionary": ["title": title]]
        }
        func list(_ uuid: String, _ title: String, _ children: [[String: Any]]) -> [String: Any] {
            ["WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": uuid,
             "Title": title, "Children": children]
        }
        let root = list("root", "", [
            list("bar", "BookmarksBar", [
                leaf("l1", "Apple", "https://apple.com"),
                leaf("l2", "Swift", "https://swift.org"),
                list("sub", "Dev", [leaf("l3", "GitHub", "https://github.com")])
            ]),
            list("rl", "com.apple.ReadingList", [
                leaf("rl1", "Read later", "https://example.com/article")
            ])
        ])
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("safari-fixture-\(UUID().uuidString).plist")
        try data.write(to: url)
        return url
    }

    private func makeClient() throws -> (SafariSourceClient, URL) {
        let url = try writeFixture()
        return (SafariSourceClient(reader: SafariBookmarkReader(fileURL: url)), url)
    }

    // MARK: Scopes

    func test_list_scopes_offers_all_and_each_folder_excluding_reading_list() async throws {
        let (client, url) = try makeClient()
        defer { try? FileManager.default.removeItem(at: url) }

        let scopes = try await client.listScopes()
        let names = scopes.map(\.name)

        XCTAssertTrue(names.contains("All bookmarks"))
        XCTAssertTrue(names.contains("Bookmarks Bar"))
        XCTAssertTrue(names.contains("Bookmarks Bar / Dev"))
        XCTAssertFalse(names.contains { $0.contains("ReadingList") }, "Reading List must not be a scope")

        let all = scopes.first { $0.id == SafariSourceConfig.allScopeId }
        XCTAssertEqual(all?.itemCount, 3, "All bookmarks counts the 3 leaves, not the reading-list item")
    }

    // MARK: Items

    func test_list_items_for_all_returns_every_bookmark_with_urls() async throws {
        let (client, url) = try makeClient()
        defer { try? FileManager.default.removeItem(at: url) }

        let items = try await client.listItems(config: .safari(
            SafariSourceConfig(folderId: SafariSourceConfig.allScopeId, folderName: "All bookmarks")))

        XCTAssertEqual(Set(items.map(\.id)), ["l1", "l2", "l3"])
        XCTAssertEqual(items.first { $0.id == "l1" }?.url, URL(string: "https://apple.com"))
        XCTAssertEqual(items.first { $0.id == "l1" }?.name, "Apple")
        // Reading-list item is excluded.
        XCTAssertFalse(items.contains { $0.id == "rl1" })
    }

    func test_list_items_scoped_to_a_subfolder() async throws {
        let (client, url) = try makeClient()
        defer { try? FileManager.default.removeItem(at: url) }

        let items = try await client.listItems(config: .safari(
            SafariSourceConfig(folderId: "sub", folderName: "Dev")))

        XCTAssertEqual(items.map(\.id), ["l3"])
        XCTAssertEqual(items.first?.url, URL(string: "https://github.com"))
    }

    func test_version_hash_changes_with_url_or_title() async throws {
        let (client, url) = try makeClient()
        defer { try? FileManager.default.removeItem(at: url) }

        let items = try await client.listItems(config: .safari(
            SafariSourceConfig(folderId: SafariSourceConfig.allScopeId, folderName: "All")))
        let apple = items.first { $0.id == "l1" }
        let swift = items.first { $0.id == "l2" }
        XCTAssertNotEqual(apple?.versionHash, swift?.versionHash)
    }

    // MARK: Content / title

    func test_content_is_empty_and_never_suppressed() async throws {
        let client = SafariSourceClient(reader: SafariBookmarkReader(fileURL: try writeFixture()))
        let item = SourceItem(id: "l1", name: "Apple", versionHash: "h",
                              createdAt: .distantPast, url: URL(string: "https://apple.com"))
        let config = SourceConfiguration.safari(SafariSourceConfig(folderId: "x", folderName: "x"))

        let content = try await client.content(for: item, config: config)
        XCTAssertTrue(content.blocks.isEmpty)
        XCTAssertFalse(client.shouldSkipAsEmpty(content: content, config: config, ocrModeOverride: nil))
    }

    func test_resolve_title_uses_bookmark_title_then_host() async throws {
        let client = SafariSourceClient(reader: SafariBookmarkReader(fileURL: try writeFixture()))
        let config = SourceConfiguration.safari(SafariSourceConfig(folderId: "x", folderName: "x"))
        let named = SourceItem(id: "l1", name: "Apple", versionHash: "h",
                               createdAt: .distantPast, url: URL(string: "https://apple.com"))
        let unnamed = SourceItem(id: "l2", name: "", versionHash: "h",
                                 createdAt: .distantPast, url: URL(string: "https://swift.org"))
        XCTAssertEqual(client.resolveTitle(for: named, content: NoteContent(blocks: []), config: config, strategyOverride: nil), "Apple")
        XCTAssertEqual(client.resolveTitle(for: unnamed, content: NoteContent(blocks: []), config: config, strategyOverride: nil), "swift.org")
    }

    // MARK: Parsing errors

    func test_malformed_plist_throws() {
        let garbage = Data("not a plist".utf8)
        XCTAssertThrowsError(try SafariBookmarkReader.parseRoot(data: garbage))
    }
}
