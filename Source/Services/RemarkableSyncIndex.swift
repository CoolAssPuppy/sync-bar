//
//  RemarkableSyncIndex.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Pure parsers for the reMarkable cloud "sync 1.5 / v3" content-addressed
//  blob store. The store works like a tiny git: a root index lists one entry
//  per document; each document's hash points to its own index, which lists the
//  component blobs (.metadata, .content, and one .rm per page). These parsers
//  turn the raw index/JSON blobs into domain values. The wire endpoints are
//  reverse-engineered and must be confirmed against a live device; the formats
//  parsed here are stable and unit-tested with fixtures.
//

import Foundation

enum RemarkableSyncError: LocalizedError {
    case malformedIndex(String)

    var errorDescription: String? {
        switch self {
        case .malformedIndex(let detail): return "reMarkable index was malformed: \(detail)"
        }
    }
}

/// One line of a sync index blob: `<hash>:<type>:<id>:<subfiles>:<size>`.
struct RemarkableIndexEntry: Equatable {
    let hash: String
    let type: String
    /// Document UUID (root index) or component filename like `<uuid>.metadata`
    /// or `<uuid>/<pageUuid>.rm` (document index).
    let identifier: String
    let subfiles: Int
    let size: Int
}

/// One line of the schema-4 *root* index, which differs from the per-document
/// index (`RemarkableIndexEntry`): the root lists documents, not component
/// blobs. Line shape: `<docHash>:0:<uuid>:<numFiles>:<size>`.
struct RootDocLine: Equatable {
    let hash: String
    let id: String
    let numFiles: Int
    let size: Int
}

/// Decoded `.metadata` blob for one document.
struct RemarkableMetadata: Equatable {
    let visibleName: String
    let type: String           // "DocumentType" or "CollectionType"
    let parent: String
    let createdTime: Date
    let lastModified: Date
    let deleted: Bool

    /// reMarkable moves a trashed item to a reserved "trash" parent rather than
    /// setting `deleted` (which is reserved for tombstoned/purged items). Both
    /// must be excluded for a listing to reflect what's actually on the device.
    var isTrashed: Bool { parent == "trash" }
    var isLive: Bool { !deleted && !isTrashed }

    var isNotebook: Bool { type == "DocumentType" && isLive }
    var isFolder: Bool { type == "CollectionType" && isLive }
}

enum RemarkableSyncIndex {

    /// Parses a root or document index blob. The first line is the schema
    /// version (e.g. "3") and is skipped.
    static func parseIndex(_ text: String) throws -> [RemarkableIndexEntry] {
        var lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        guard !lines.isEmpty else { return [] }
        // Drop the schema-version header line (a bare integer).
        if Int(lines[0]) != nil { lines.removeFirst() }
        // Schema-4 indexes carry a summary line `0:<name>:<count>:<size>` after
        // the header; skip it. A real entry never has 4 fields or a "0" hash.
        if let first = lines.first {
            let fields = first.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if fields.count == 4 && fields[0] == "0" { lines.removeFirst() }
        }

        return try lines.map { line in
            let fields = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5 else {
                throw RemarkableSyncError.malformedIndex("expected 5 colon-separated fields, got \(fields.count) in \"\(line)\"")
            }
            return RemarkableIndexEntry(
                hash: fields[0],
                type: fields[1],
                identifier: fields[2],
                subfiles: Int(fields[3]) ?? 0,
                size: Int(fields[4]) ?? 0
            )
        }
    }

    /// The `.metadata` component entry in a document index, if present.
    static func metadataEntry(in entries: [RemarkableIndexEntry]) -> RemarkableIndexEntry? {
        entries.first { $0.identifier.hasSuffix(".metadata") }
    }

    /// The `.content` component entry in a document index, if present.
    static func contentEntry(in entries: [RemarkableIndexEntry]) -> RemarkableIndexEntry? {
        entries.first { $0.identifier.hasSuffix(".content") }
    }

    /// Maps page UUID -> its `.rm` blob hash, from a document index.
    static func pageBlobHashes(in entries: [RemarkableIndexEntry]) -> [String: String] {
        var out: [String: String] = [:]
        for entry in entries where entry.identifier.hasSuffix(".rm") {
            let file = (entry.identifier as NSString).lastPathComponent          // <pageUuid>.rm
            let pageUuid = (file as NSString).deletingPathExtension
            out[pageUuid] = entry.hash
        }
        return out
    }

    // MARK: - Serializers (upload / write path)

    /// Serializes a schema-4 index blob: header `4`, a summary line
    /// `0:<name>:<entryCount>:<totalSize>`, then the entries sorted by
    /// identifier. Current reMarkable servers content-address every index by the
    /// SHA-256 of these exact bytes and reject the old v3 format with HTTP 400
    /// "invalid hash" — for both the root AND each per-document index.
    private static func serializeIndexV4(summaryName: String, entries: [RemarkableIndexEntry]) -> String {
        let sorted = entries.sorted { $0.identifier < $1.identifier }
        let totalSize = sorted.reduce(0) { $0 + $1.size }
        var out = "4\n"
        out += "0:\(summaryName):\(sorted.count):\(totalSize)\n"
        for entry in sorted {
            out += "\(entry.hash):\(entry.type):\(entry.identifier):\(entry.subfiles):\(entry.size)\n"
        }
        return out
    }

    /// The per-document index blob. The summary line's name is the document's own
    /// UUID (the root uses `.`). Components are leaf entries (type `0`, subfiles
    /// `0`).
    static func serializeDocumentIndex(documentId: String, entries: [RemarkableIndexEntry]) -> String {
        serializeIndexV4(summaryName: documentId, entries: entries)
    }

    /// The root index blob. The summary line's name is `.`; each document is a
    /// line `<docHash>:0:<uuid>:<numFiles>:<size>`.
    static func serializeRootIndex(_ docs: [RootDocLine]) -> String {
        let entries = docs.map {
            RemarkableIndexEntry(hash: $0.hash, type: "0", identifier: $0.id, subfiles: $0.numFiles, size: $0.size)
        }
        return serializeIndexV4(summaryName: ".", entries: entries)
    }

    /// Parses a root index blob into its document lines, so a new document can be
    /// spliced in before re-serializing. Tolerates both schema-3 roots (legacy,
    /// no summary line, type field `80000000`) and schema-4 roots (a `0:.:…`
    /// summary line that we skip and recompute on write). The per-line type field
    /// is ignored, so both formats read the same.
    static func parseRootIndexV4(_ text: String) throws -> [RootDocLine] {
        var lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        guard !lines.isEmpty else { return [] }
        if Int(lines[0]) != nil { lines.removeFirst() }            // schema header
        if let first = lines.first {                                // v4 summary line
            let fields = first.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if fields.count >= 2 && fields[1] == "." { lines.removeFirst() }
        }
        return try lines.map { line in
            let fields = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5 else {
                throw RemarkableSyncError.malformedIndex("expected 5 colon-separated fields, got \(fields.count) in \"\(line)\"")
            }
            return RootDocLine(
                hash: fields[0],
                id: fields[2],
                numFiles: Int(fields[3]) ?? 0,
                size: Int(fields[4]) ?? 0
            )
        }
    }

    /// Builds a `.metadata` JSON blob for an uploaded document. `parent` is the
    /// destination folder UUID, or "" for the cloud root ("My Files").
    /// `lastModified` is written as milliseconds-since-epoch *as a string*
    /// (inverse of `parseMetadata`, which divides by 1000).
    static func serializeMetadata(visibleName: String,
                                  parent: String,
                                  type: String,
                                  lastModified: Date) throws -> Data {
        struct MetadataBlob: Encodable {
            let visibleName: String
            let type: String
            let parent: String
            let lastModified: String
            let lastOpened: String
            let lastOpenedPage: Int
            let version: Int
            let pinned: Bool
            let synced: Bool
            let modified: Bool
            let deleted: Bool
            let metadatamodified: Bool
        }
        let millis = String(Int64((lastModified.timeIntervalSince1970 * 1000).rounded()))
        let blob = MetadataBlob(
            visibleName: visibleName, type: type, parent: parent,
            lastModified: millis, lastOpened: "", lastOpenedPage: 0, version: 0,
            pinned: false, synced: true, modified: false, deleted: false,
            metadatamodified: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(blob)
    }

    /// Builds a `.content` JSON blob for an uploaded PDF/EPUB. For a PDF we list
    /// one page UUID per page (annotation layers the device fills in lazily);
    /// EPUB is reflowable so it carries no fixed pages. `formatVersion` is
    /// deliberately omitted — rmapi omits it and uploads still succeed (the
    /// device normalizes it on first open).
    static func serializeContent(fileType: String, pageCount: Int) throws -> Data {
        struct ContentBlob: Encodable {
            let fileType: String
            let pageCount: Int
            let pages: [String]
            let coverPageNumber: Int
            let dummyDocument: Bool
            let fontName: String
            let lineHeight: Int
            let margins: Int
            let orientation: String
            let textScale: Int
        }
        let pages = (0..<max(0, pageCount)).map { _ in UUID().uuidString.lowercased() }
        let blob = ContentBlob(
            fileType: fileType, pageCount: pageCount, pages: pages,
            coverPageNumber: 0, dummyDocument: false, fontName: "",
            lineHeight: -1, margins: 125, orientation: "portrait", textScale: 1
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(blob)
    }

    static func parseMetadata(_ data: Data) throws -> RemarkableMetadata {
        struct Raw: Decodable {
            let visibleName: String?
            let type: String?
            let parent: String?
            let createdTime: String?
            let lastModified: String?
            let deleted: Bool?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        let modifiedMillis = Double(raw.lastModified ?? "") ?? 0
        let createdMillis = Double(raw.createdTime ?? "") ?? modifiedMillis
        return RemarkableMetadata(
            visibleName: raw.visibleName ?? "Untitled",
            type: raw.type ?? "DocumentType",
            parent: raw.parent ?? "",
            createdTime: Date(timeIntervalSince1970: createdMillis / 1000),
            lastModified: Date(timeIntervalSince1970: modifiedMillis / 1000),
            deleted: raw.deleted ?? false
        )
    }

    /// Page UUIDs in display order from a `.content` blob. Handles both the
    /// modern `cPages.pages[].id` shape and the legacy `pages[]` string array.
    static func parseContentPageOrder(_ data: Data) throws -> [String] {
        struct CPage: Decodable { let id: String?; let deleted: DeletedFlag? }
        struct DeletedFlag: Decodable { let value: Int? }
        struct CPages: Decodable { let pages: [CPage]? }
        struct Raw: Decodable {
            let cPages: CPages?
            let pages: [String]?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        if let cPages = raw.cPages?.pages {
            return cPages.compactMap { page in
                guard (page.deleted?.value ?? 0) == 0 else { return nil }
                return page.id
            }
        }
        return raw.pages ?? []
    }

    /// All tag names from a `.content` blob. reMarkable tags live in three
    /// places depending on app version and whether the tag is on the whole note
    /// or a single page:
    ///   - `tags: [{name}]`                  whole-note tags
    ///   - `pageTags: [{name}]`              legacy page tags (flat)
    ///   - `cPages.pages[].tags: [{name}]`   modern page tags (per page)
    /// We treat a note as carrying a tag if the tag appears anywhere in it, so a
    /// note with a "sync"-tagged page filters the same as one tagged as a whole.
    /// Blank names are dropped and duplicates collapsed (order preserved).
    /// Returns [] when the blob has no tags.
    static func parseContentTags(_ data: Data) throws -> [String] {
        struct Tag: Decodable { let name: String? }
        struct Page: Decodable { let tags: [Tag]? }
        struct CPages: Decodable { let pages: [Page]? }
        struct Raw: Decodable {
            let tags: [Tag]?
            let pageTags: [Tag]?
            let cPages: CPages?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        let all = (raw.tags ?? [])
            + (raw.pageTags ?? [])
            + (raw.cPages?.pages ?? []).flatMap { $0.tags ?? [] }
        var seen = Set<String>()
        return all.compactMap { tag -> String? in
            let name = tag.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
    }
}
