//
//  RemarkableSyncIndexTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

final class RemarkableSyncIndexTests: XCTestCase {

    func test_parseIndex_skips_schema_header_and_splits_fields() throws {
        let text = """
        3
        abc123:80000000:doc-uuid-1:5:0
        def456:80000000:doc-uuid-2:3:0
        """
        let entries = try RemarkableSyncIndex.parseIndex(text)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0], RemarkableIndexEntry(hash: "abc123", type: "80000000", identifier: "doc-uuid-1", subfiles: 5, size: 0))
        XCTAssertEqual(entries[1].identifier, "doc-uuid-2")
    }

    func test_parseIndex_rejects_short_lines() {
        XCTAssertThrowsError(try RemarkableSyncIndex.parseIndex("3\nbroken:line"))
    }

    func test_documentIndex_component_lookups() throws {
        let text = """
        3
        h1:0:doc-uuid-1.metadata:0:120
        h2:0:doc-uuid-1.content:0:340
        h3:0:doc-uuid-1/page-aaa.rm:0:900
        h4:0:doc-uuid-1/page-bbb.rm:0:880
        """
        let entries = try RemarkableSyncIndex.parseIndex(text)
        XCTAssertEqual(RemarkableSyncIndex.metadataEntry(in: entries)?.hash, "h1")
        XCTAssertEqual(RemarkableSyncIndex.contentEntry(in: entries)?.hash, "h2")
        let pages = RemarkableSyncIndex.pageBlobHashes(in: entries)
        XCTAssertEqual(pages, ["page-aaa": "h3", "page-bbb": "h4"])
    }

    func test_parseMetadata_decodes_notebook() throws {
        let json = #"{"visibleName":"My Notebook","type":"DocumentType","parent":"","lastModified":"1700000000000","deleted":false}"#
        let meta = try RemarkableSyncIndex.parseMetadata(Data(json.utf8))
        XCTAssertEqual(meta.visibleName, "My Notebook")
        XCTAssertTrue(meta.isNotebook)
        XCTAssertEqual(meta.lastModified.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
    }

    func test_parseMetadata_marks_folders_and_deleted() throws {
        let folder = #"{"visibleName":"F","type":"CollectionType","lastModified":"0"}"#
        XCTAssertTrue(try RemarkableSyncIndex.parseMetadata(Data(folder.utf8)).isFolder)
        let deleted = #"{"visibleName":"D","type":"DocumentType","deleted":true,"lastModified":"0"}"#
        XCTAssertFalse(try RemarkableSyncIndex.parseMetadata(Data(deleted.utf8)).isNotebook)
    }

    func test_parseContentPageOrder_modern_cPages_skips_deleted() throws {
        let json = #"{"cPages":{"pages":[{"id":"p1"},{"id":"p2","deleted":{"value":1}},{"id":"p3"}]}}"#
        XCTAssertEqual(try RemarkableSyncIndex.parseContentPageOrder(Data(json.utf8)), ["p1", "p3"])
    }

    func test_parseContentPageOrder_legacy_string_array() throws {
        let json = #"{"pages":["a","b","c"]}"#
        XCTAssertEqual(try RemarkableSyncIndex.parseContentPageOrder(Data(json.utf8)), ["a", "b", "c"])
    }

    func test_parseContentTags_reads_document_tag_names() throws {
        let json = #"{"tags":[{"name":"Linear","timestamp":1},{"name":"Idea","timestamp":2}]}"#
        XCTAssertEqual(try RemarkableSyncIndex.parseContentTags(Data(json.utf8)), ["Linear", "Idea"])
    }

    func test_parseContentTags_returns_empty_when_absent_or_blank() throws {
        XCTAssertEqual(try RemarkableSyncIndex.parseContentTags(Data(#"{"pages":["a"]}"#.utf8)), [])
        let blank = #"{"tags":[{"name":"","timestamp":1},{"name":"Keep","timestamp":2}]}"#
        XCTAssertEqual(try RemarkableSyncIndex.parseContentTags(Data(blank.utf8)), ["Keep"])
    }

    func test_parseContentTags_reads_legacy_flat_page_tags() throws {
        let json = #"{"pageTags":[{"name":"sync","timestamp":1}]}"#
        XCTAssertEqual(try RemarkableSyncIndex.parseContentTags(Data(json.utf8)), ["sync"])
    }

    func test_parseContentTags_reads_modern_per_page_tags() throws {
        let json = #"{"cPages":{"pages":[{"id":"p1","tags":[{"name":"sync"}]},{"id":"p2"}]}}"#
        XCTAssertEqual(try RemarkableSyncIndex.parseContentTags(Data(json.utf8)), ["sync"])
    }

    func test_parseContentTags_merges_and_dedupes_across_locations() throws {
        let json = #"""
        {"tags":[{"name":"sync"}],
         "pageTags":[{"name":"sync"},{"name":"draft"}],
         "cPages":{"pages":[{"id":"p1","tags":[{"name":"draft"},{"name":"idea"}]}]}}
        """#
        XCTAssertEqual(try RemarkableSyncIndex.parseContentTags(Data(json.utf8)), ["sync", "draft", "idea"])
    }

    func test_trashed_document_is_not_live_even_when_deleted_flag_is_false() throws {
        let json = #"{"visibleName":"Old Note","type":"DocumentType","parent":"trash","deleted":false,"lastModified":"1"}"#
        let meta = try RemarkableSyncIndex.parseMetadata(Data(json.utf8))
        XCTAssertTrue(meta.isTrashed)
        XCTAssertFalse(meta.isLive)
        XCTAssertFalse(meta.isNotebook, "a trashed notebook must not list as a notebook")
    }

    func test_live_document_in_a_folder_is_a_notebook() throws {
        let json = #"{"visibleName":"Active","type":"DocumentType","parent":"some-folder-id","deleted":false,"lastModified":"1"}"#
        let meta = try RemarkableSyncIndex.parseMetadata(Data(json.utf8))
        XCTAssertTrue(meta.isLive)
        XCTAssertTrue(meta.isNotebook)
    }

    func test_parseRootHash_handles_json_and_plain() {
        let json = #"{"hash":"roothash","generation":5}"#
        XCTAssertEqual(RealRemarkableClient.parseRootHash(Data(json.utf8)), "roothash")
        XCTAssertEqual(RealRemarkableClient.parseRootHash(Data("plainhash\n".utf8)), "plainhash")
    }
}
