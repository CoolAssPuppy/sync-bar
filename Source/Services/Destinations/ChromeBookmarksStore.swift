//
//  ChromeBookmarksStore.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation
import CryptoKit

enum ChromeBookmarksError: LocalizedError, Sendable {
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let message): return "Chrome bookmarks file is malformed: \(message)"
        }
    }
}

/// Parses, mutates, and re-serializes Chrome's `Bookmarks` JSON. Works on the
/// raw object graph (NSMutable containers) so unknown keys Chrome cares about
/// (meta_info, sync_metadata, …) are preserved on write. On serialize it
/// recomputes the top-level MD5 `checksum` that Chrome validates; an incorrect
/// checksum makes Chrome discard the file, so this is the load-bearing bit and
/// is covered by a lock test.
final class ChromeBookmarksStore {
    private let root: NSMutableDictionary

    init(data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data, options: [.mutableContainers, .mutableLeaves])
        guard let dict = object as? NSMutableDictionary else {
            throw ChromeBookmarksError.malformed("root is not an object")
        }
        self.root = dict
    }

    /// The guid of a bookmark with `url` directly under the given folder path, if
    /// present. Used for idempotency: "is this URL already in the target folder?"
    func guid(forURL url: String, inFolderPath path: [String]) -> String? {
        guard let folder = folder(atPath: path, create: false) else { return nil }
        for case let child as NSDictionary in childrenArray(of: folder) where (child["type"] as? String) == "url" {
            if (child["url"] as? String) == url { return child["guid"] as? String }
        }
        return nil
    }

    /// Adds a `url` bookmark under the given folder path (creating folders as
    /// needed) and returns its new guid.
    @discardableResult
    func addBookmark(name: String, url: String, folderPath: [String], now: Date = Date()) throws -> String {
        guard let folder = folder(atPath: folderPath, create: true) else {
            throw ChromeBookmarksError.malformed("could not resolve folder path \(folderPath)")
        }
        let guid = UUID().uuidString.lowercased()
        let node: NSMutableDictionary = [
            "type": "url",
            "name": name,
            "url": url,
            "guid": guid,
            "id": String(nextId()),
            "date_added": Self.chromeTimestamp(now)
        ]
        childrenArray(of: folder).add(node)
        return guid
    }

    /// Recomputes the checksum and serializes back to JSON bytes.
    func serialized() throws -> Data {
        if let roots = root["roots"] as? NSDictionary {
            root["checksum"] = Self.checksum(roots: roots)
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: Folder navigation

    /// Resolves a folder path. The first component selects a Chrome root
    /// (Bookmarks Bar / Other / Mobile); the rest are nested folder names,
    /// created when `create` is true.
    private func folder(atPath path: [String], create: Bool) -> NSMutableDictionary? {
        guard let roots = root["roots"] as? NSMutableDictionary else { return nil }
        let rootName = path.first ?? "Bookmarks Bar"
        guard var current = roots[Self.rootKey(for: rootName)] as? NSMutableDictionary else { return nil }
        for folderName in path.dropFirst() {
            guard let next = childFolder(named: folderName, in: current, create: create) else { return nil }
            current = next
        }
        return current
    }

    private func childFolder(named name: String, in folder: NSMutableDictionary, create: Bool) -> NSMutableDictionary? {
        let children = childrenArray(of: folder)
        for case let child as NSMutableDictionary in children
        where (child["type"] as? String) == "folder" && (child["name"] as? String) == name {
            return child
        }
        guard create else { return nil }
        let newFolder: NSMutableDictionary = [
            "type": "folder",
            "name": name,
            "guid": UUID().uuidString.lowercased(),
            "id": String(nextId()),
            "date_added": Self.chromeTimestamp(Date()),
            "children": NSMutableArray()
        ]
        children.add(newFolder)
        return newFolder
    }

    private func childrenArray(of folder: NSMutableDictionary) -> NSMutableArray {
        if let array = folder["children"] as? NSMutableArray { return array }
        let array = NSMutableArray()
        folder["children"] = array
        return array
    }

    /// One past the largest numeric id anywhere in the tree, so new nodes don't
    /// collide. (Chrome reassigns ids on its own, but we must not duplicate one
    /// within a single write.)
    private func nextId() -> Int {
        var maxId = 0
        func walk(_ node: NSDictionary) {
            if let idString = node["id"] as? String, let id = Int(idString) { maxId = max(maxId, id) }
            for case let child as NSDictionary in (node["children"] as? NSArray ?? []) { walk(child) }
        }
        if let roots = root["roots"] as? NSDictionary {
            for case let node as NSDictionary in roots.allValues { walk(node) }
        }
        return maxId + 1
    }

    /// Maps a folder display name to a Chrome root key.
    static func rootKey(for name: String) -> String {
        switch name.lowercased() {
        case "other", "other bookmarks":       return "other"
        case "mobile", "mobile bookmarks", "synced": return "synced"
        default:                                return "bookmark_bar"  // "Bookmarks Bar" / "Favorites"
        }
    }

    /// Microseconds since 1601-01-01 UTC (Chrome's epoch), as a decimal string.
    static func chromeTimestamp(_ date: Date) -> String {
        let secondsBetween1601And1970 = 11_644_473_600.0
        let micros = Int64((date.timeIntervalSince1970 + secondsBetween1601And1970) * 1_000_000)
        return String(micros)
    }

    // MARK: Checksum (ported from Chromium bookmark_codec; locked by a test)

    /// MD5 over a depth-first walk of the three roots in order. For a url node:
    /// id + name(UTF-16LE) + "url" + url. For a folder: id + name(UTF-16LE) +
    /// "folder" + recurse. meta_info / the checksum field itself are excluded.
    static func checksum(roots: NSDictionary) -> String {
        var md5 = Insecure.MD5()
        for key in ["bookmark_bar", "other", "synced"] {
            if let node = roots[key] as? NSDictionary { update(&md5, node: node) }
        }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func update(_ md5: inout Insecure.MD5, node: NSDictionary) {
        let id = node["id"] as? String ?? ""
        let name = node["name"] as? String ?? ""
        let type = node["type"] as? String ?? ""
        md5.update(data: Data(id.utf8))
        md5.update(data: utf16LE(name))
        if type == "url" {
            md5.update(data: Data("url".utf8))
            md5.update(data: Data((node["url"] as? String ?? "").utf8))
        } else {
            md5.update(data: Data("folder".utf8))
            for case let child as NSDictionary in (node["children"] as? NSArray ?? []) {
                update(&md5, node: child)
            }
        }
    }

    private static func utf16LE(_ string: String) -> Data {
        var data = Data(capacity: string.utf16.count * 2)
        for unit in string.utf16 {
            data.append(UInt8(unit & 0xff))
            data.append(UInt8(unit >> 8))
        }
        return data
    }
}
