//
//  SafariBookmarkReader.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// One node in Safari's bookmark tree, normalized from the plist. A leaf is a
/// bookmark (has a URL); a folder has children. `uuid` is Safari's stable
/// `WebBookmarkUUID`, used as the sync key.
struct SafariBookmarkNode: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case leaf(url: String)
        case folder
    }
    var uuid: String
    var title: String
    var kind: Kind
    var children: [SafariBookmarkNode] = []

    var isReadingList: Bool { title == "com.apple.ReadingList" }
}

enum SafariBookmarkReaderError: LocalizedError, Sendable {
    case notReadable        // file missing or no Full Disk Access
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .notReadable:
            return "Couldn't read Safari bookmarks."
        case .parseFailed(let message):
            return "Couldn't parse Safari bookmarks: \(message)"
        }
    }
}

/// Reads and parses `~/Library/Safari/Bookmarks.plist` (a binary plist). Walks
/// the `WebBookmarkType` tree into normalized `SafariBookmarkNode`s. Read-only.
struct SafariBookmarkReader: Sendable {
    let fileURL: URL

    init(fileURL: URL = FullDiskAccessProbe.safariBookmarksURL) {
        self.fileURL = fileURL
    }

    /// The root bookmark folder. Its children are the top-level lists
    /// (Bookmarks Bar, Bookmarks Menu, Reading List, ...).
    func readRoot() throws -> SafariBookmarkNode {
        guard let data = try? Data(contentsOf: fileURL) else {
            throw SafariBookmarkReaderError.notReadable
        }
        return try Self.parseRoot(data: data)
    }

    /// Parses a plist blob into the root node. Exposed for tests (which build a
    /// fixture with `PropertyListSerialization`).
    static func parseRoot(data: Data) throws -> SafariBookmarkNode {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw SafariBookmarkReaderError.parseFailed(error.localizedDescription)
        }
        guard let dict = object as? [String: Any] else {
            throw SafariBookmarkReaderError.parseFailed("root is not a dictionary")
        }
        guard let node = parseNode(dict) else {
            throw SafariBookmarkReaderError.parseFailed("root is not a bookmark list")
        }
        return node
    }

    private static func parseNode(_ dict: [String: Any]) -> SafariBookmarkNode? {
        let type = dict["WebBookmarkType"] as? String
        let uuid = dict["WebBookmarkUUID"] as? String ?? UUID().uuidString

        switch type {
        case "WebBookmarkTypeLeaf":
            guard let url = dict["URLString"] as? String else { return nil }
            let title = (dict["URIDictionary"] as? [String: Any])?["title"] as? String ?? url
            return SafariBookmarkNode(uuid: uuid, title: title, kind: .leaf(url: url))

        case "WebBookmarkTypeList":
            let title = dict["Title"] as? String ?? ""
            let rawChildren = (dict["Children"] as? [[String: Any]]) ?? []
            let children = rawChildren.compactMap(parseNode)
            return SafariBookmarkNode(uuid: uuid, title: title, kind: .folder, children: children)

        default:
            // WebBookmarkTypeProxy (History, etc.) and anything unknown is skipped.
            return nil
        }
    }
}
