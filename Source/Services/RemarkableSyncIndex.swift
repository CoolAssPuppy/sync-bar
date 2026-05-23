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
