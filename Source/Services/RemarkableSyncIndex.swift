//
//  RemarkableSyncIndex.swift
//  SyncNerds
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

/// Decoded `.metadata` blob for one document.
struct RemarkableMetadata: Equatable {
    let visibleName: String
    let type: String           // "DocumentType" or "CollectionType"
    let parent: String
    let lastModified: Date
    let deleted: Bool

    var isNotebook: Bool { type == "DocumentType" && !deleted }
    var isFolder: Bool { type == "CollectionType" && !deleted }
}

enum RemarkableSyncIndex {

    /// Parses a root or document index blob. The first line is the schema
    /// version (e.g. "3") and is skipped.
    static func parseIndex(_ text: String) throws -> [RemarkableIndexEntry] {
        var lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        guard !lines.isEmpty else { return [] }
        // Drop the schema-version header line (a bare integer).
        if Int(lines[0]) != nil { lines.removeFirst() }

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

    static func parseMetadata(_ data: Data) throws -> RemarkableMetadata {
        struct Raw: Decodable {
            let visibleName: String?
            let type: String?
            let parent: String?
            let lastModified: String?
            let deleted: Bool?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        let millis = Double(raw.lastModified ?? "") ?? 0
        return RemarkableMetadata(
            visibleName: raw.visibleName ?? "Untitled",
            type: raw.type ?? "DocumentType",
            parent: raw.parent ?? "",
            lastModified: Date(timeIntervalSince1970: millis / 1000),
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
}
