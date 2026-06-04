//
//  RemarkableUploadTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Pins the wire formats the live reMarkable upload depends on: index/metadata/
//  content serializers, CRC32C, the document/leaf hashing rules, and the
//  pluralized result-banner copy. All pure — no network.
//

import XCTest
@testable import SyncBar

final class RemarkableUploadTests: XCTestCase {

    // MARK: Document index (schema 3)

    func test_serializeDocumentIndex_is_v4_and_roundtrips() throws {
        let entries = [
            RemarkableIndexEntry(hash: "aaa", type: "0", identifier: "doc.pdf", subfiles: 0, size: 1234),
            RemarkableIndexEntry(hash: "bbb", type: "0", identifier: "doc.metadata", subfiles: 0, size: 88),
            RemarkableIndexEntry(hash: "ccc", type: "0", identifier: "doc.content", subfiles: 0, size: 41)
        ]
        let text = RemarkableSyncIndex.serializeDocumentIndex(documentId: "doc", entries: entries)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines[0], "4")
        // Summary names the document and totals the component sizes (1234+88+41).
        XCTAssertEqual(lines[1], "0:doc:3:1363")
        // Lines are sorted by identifier (.content < .metadata < .pdf), and the
        // reader (tolerating the v4 summary) recovers them in that order.
        XCTAssertEqual(try RemarkableSyncIndex.parseIndex(text),
                       entries.sorted { $0.identifier < $1.identifier })
    }

    // MARK: Root index (schema 4)

    func test_serializeRootIndex_emits_v4_with_summary_line() {
        let docs = [
            RootDocLine(hash: "h1", id: "doc-1", numFiles: 3, size: 100),
            RootDocLine(hash: "h2", id: "doc-2", numFiles: 4, size: 250)
        ]
        let text = RemarkableSyncIndex.serializeRootIndex(docs)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "4")
        XCTAssertEqual(lines[1], "0:.:2:350")          // count and total size
        XCTAssertEqual(lines[2], "h1:0:doc-1:3:100")
    }

    func test_parseRootIndexV4_roundtrips() throws {
        let docs = [
            RootDocLine(hash: "h1", id: "doc-1", numFiles: 3, size: 100),
            RootDocLine(hash: "h2", id: "doc-2", numFiles: 4, size: 250)
        ]
        let parsed = try RemarkableSyncIndex.parseRootIndexV4(RemarkableSyncIndex.serializeRootIndex(docs))
        XCTAssertEqual(parsed, docs)
    }

    func test_parseRootIndexV4_reads_legacy_schema3_root() throws {
        // Old roots have no summary line and use type 80000000; we ignore type.
        let text = "3\nh1:80000000:doc-1:3:100\n"
        let parsed = try RemarkableSyncIndex.parseRootIndexV4(text)
        XCTAssertEqual(parsed, [RootDocLine(hash: "h1", id: "doc-1", numFiles: 3, size: 100)])
    }

    func test_parseRootIndexV4_empty_root() throws {
        XCTAssertEqual(try RemarkableSyncIndex.parseRootIndexV4(RemarkableSyncIndex.serializeRootIndex([])), [])
    }

    // MARK: Metadata / content

    func test_serializeMetadata_roundtrips_with_parseMetadata() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try RemarkableSyncIndex.serializeMetadata(
            visibleName: "My Book", parent: "folder-uuid", type: "DocumentType", lastModified: when)
        let meta = try RemarkableSyncIndex.parseMetadata(data)
        XCTAssertEqual(meta.visibleName, "My Book")
        XCTAssertEqual(meta.type, "DocumentType")
        XCTAssertEqual(meta.parent, "folder-uuid")
        XCTAssertFalse(meta.deleted)
        XCTAssertEqual(meta.lastModified.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
    }

    func test_serializeMetadata_root_uses_empty_parent() throws {
        let data = try RemarkableSyncIndex.serializeMetadata(
            visibleName: "Loose", parent: "", type: "DocumentType", lastModified: Date())
        XCTAssertEqual(try RemarkableSyncIndex.parseMetadata(data).parent, "")
    }

    func test_serializeContent_pdf_lists_one_page_uuid_per_page() throws {
        let data = try RemarkableSyncIndex.serializeContent(fileType: "pdf", pageCount: 3)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["fileType"] as? String, "pdf")
        XCTAssertEqual(json["pageCount"] as? Int, 3)
        XCTAssertEqual((json["pages"] as? [String])?.count, 3)
    }

    func test_serializeContent_epub_has_no_pages() throws {
        let data = try RemarkableSyncIndex.serializeContent(fileType: "epub", pageCount: 0)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["fileType"] as? String, "epub")
        XCTAssertEqual((json["pages"] as? [String])?.count, 0)
    }

    // MARK: CRC32C

    func test_crc32c_known_answer() {
        // The canonical CRC32C check value for "123456789".
        XCTAssertEqual(CRC32C.checksum(Data("123456789".utf8)), 0xE306_9283)
    }

    func test_crc32c_goog_hash_header() {
        XCTAssertEqual(CRC32C.googHashHeader(Data("123456789".utf8)), "crc32c=4waSgw==")
        XCTAssertEqual(CRC32C.googHashHeader(Data()), "crc32c=AAAAAA==")
    }

    // MARK: Hashing

    func test_leafHash_is_sha256_hex() {
        // SHA-256("hello") well-known digest.
        XCTAssertEqual(RemarkableUploader.leafHash(Data("hello".utf8)),
                       "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    // MARK: Hex helpers

    func test_hex_roundtrip() throws {
        let data = Data([0x00, 0x0f, 0xa0, 0xff])
        XCTAssertEqual(data.hexEncodedString(), "000fa0ff")
        XCTAssertEqual(Data(hexString: "000fa0ff"), data)
        XCTAssertNil(Data(hexString: "abc"))   // odd length
    }

    // MARK: Banner copy (pluralization)

    func test_banner_message_pluralization() {
        XCTAssertEqual(UploadBanner(id: UUID(), kind: .success, count: 1).message, "File uploaded successfully")
        XCTAssertEqual(UploadBanner(id: UUID(), kind: .success, count: 3).message, "3 files uploaded successfully")
        XCTAssertEqual(UploadBanner(id: UUID(), kind: .error, count: 1).message, "Error uploading file")
        XCTAssertEqual(UploadBanner(id: UUID(), kind: .error, count: 2).message, "Error uploading 2 files")
    }
}
