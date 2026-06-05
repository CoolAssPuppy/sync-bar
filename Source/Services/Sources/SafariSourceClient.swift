//
//  SafariSourceClient.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// The second `SourceClient`: Safari bookmarks (read-only). Reads
/// `~/Library/Safari/Bookmarks.plist` via `SafariBookmarkReader`. Each bookmark
/// carries its folder path, mapped to Chrome's roots (Safari Favorites →
/// Bookmarks Bar, Bookmarks Menu → Other Bookmarks), so a browser destination
/// can mirror the hierarchy rather than flatten it.
struct SafariSourceClient: SourceClient {
    let kind: SourceKind = .safari

    private let reader: SafariBookmarkReader

    init(reader: SafariBookmarkReader = SafariBookmarkReader()) {
        self.reader = reader
    }

    func listScopes() async throws -> [SourceScope] {
        let root = try readRoot()
        var scopes: [SourceScope] = [
            SourceScope(id: SafariSourceConfig.allScopeId,
                        name: "All bookmarks",
                        itemCount: leaves(under: root, includeReadingList: false).count)
        ]
        for entry in folders(under: root) {
            scopes.append(SourceScope(id: entry.node.uuid,
                                      name: entry.name,
                                      itemCount: leaves(under: entry.node, includeReadingList: true).count))
        }
        return scopes
    }

    func listItems(config: SourceConfiguration) async throws -> [SourceItem] {
        guard case .safari(let cfg) = config else {
            throw SourceError.wrongConfiguration(expected: .safari)
        }
        let root = try readRoot()
        let all = leavesWithChromePaths(root: root, includeReadingList: cfg.includeReadingList)

        let chosen: [(leaf: SafariBookmarkNode, path: [String])]
        if cfg.folderId == SafariSourceConfig.allScopeId {
            chosen = all
        } else if let scope = findFolder(under: root, uuid: cfg.folderId) {
            let inScope = Set(leaves(under: scope, includeReadingList: cfg.includeReadingList).map(\.uuid))
            chosen = all.filter { inScope.contains($0.leaf.uuid) }
        } else {
            chosen = []
        }

        return chosen.compactMap { entry in
            guard case .leaf(let url) = entry.leaf.kind else { return nil }
            return SourceItem(
                id: entry.leaf.uuid,
                name: entry.leaf.title,
                // A change to the URL, title, or folder location re-syncs.
                versionHash: "\(url)\u{1}\(entry.leaf.title)\u{1}\(entry.path.joined(separator: "/"))",
                createdAt: .distantPast,
                tags: [],
                url: URL(string: url),
                folderPath: entry.path
            )
        }
    }

    func content(for item: SourceItem, config: SourceConfiguration) async throws -> NoteContent {
        NoteContent(blocks: [])
    }

    func resolveTitle(for item: SourceItem,
                      content: NoteContent,
                      config: SourceConfiguration,
                      strategyOverride: TitleStrategy?) -> String {
        if !item.name.isEmpty { return item.name }
        return item.url?.host ?? item.url?.absoluteString ?? "Untitled bookmark"
    }

    func shouldSkipAsEmpty(content: NoteContent,
                           config: SourceConfiguration,
                           ocrModeOverride: OcrMode?) -> Bool {
        false
    }

    // MARK: Helpers

    private func readRoot() throws -> SafariBookmarkNode {
        do {
            return try reader.readRoot()
        } catch SafariBookmarkReaderError.notReadable {
            throw SourceError.unavailable("Grant Full Disk Access to read Safari bookmarks (System Settings > Privacy & Security > Full Disk Access), then relaunch Sync Bar.")
        }
    }

    /// Every leaf bookmark in the tree paired with the Chrome folder path it
    /// should mirror into: the top-level Safari list mapped to a Chrome root
    /// (Favorites → "Bookmarks Bar", Bookmarks Menu → "Other Bookmarks"), then
    /// the nested user folders verbatim. Special Apple lists (Reading List, Tab
    /// Group Favorites, …) are skipped.
    private func leavesWithChromePaths(root: SafariBookmarkNode,
                                       includeReadingList: Bool) -> [(leaf: SafariBookmarkNode, path: [String])] {
        var out: [(SafariBookmarkNode, [String])] = []
        func walk(_ node: SafariBookmarkNode, path: [String]) {
            for child in node.children {
                switch child.kind {
                case .leaf:
                    out.append((child, path))
                case .folder:
                    walk(child, path: path + [child.title])
                }
            }
        }
        for top in root.children {
            switch top.kind {
            case .leaf:
                out.append((top, []))                       // a bare URL at the root (rare)
            case .folder:
                if isExcludedTopLevel(top, includeReadingList: includeReadingList) { continue }
                walk(top, path: [Self.chromeRootName(top.title)])
            }
        }
        return out
    }

    /// Every leaf under a node, recursively (for scope item counts and filtering).
    private func leaves(under node: SafariBookmarkNode, includeReadingList: Bool) -> [SafariBookmarkNode] {
        var out: [SafariBookmarkNode] = []
        func walk(_ n: SafariBookmarkNode) {
            for child in n.children {
                switch child.kind {
                case .leaf:   out.append(child)
                case .folder:
                    if isExcludedTopLevel(child, includeReadingList: includeReadingList) { continue }
                    walk(child)
                }
            }
        }
        walk(node)
        return out
    }

    /// User-selectable folders, with a Safari-facing path name (so the dropdown
    /// reads "Favorites" / "Bookmarks Menu" like Safari shows). Special lists skipped.
    private func folders(under root: SafariBookmarkNode) -> [(node: SafariBookmarkNode, name: String)] {
        var out: [(node: SafariBookmarkNode, name: String)] = []
        func walk(_ node: SafariBookmarkNode, prefix: [String], topLevel: Bool) {
            for child in node.children where child.kind == .folder {
                if isExcludedTopLevel(child, includeReadingList: false) { continue }
                let display = topLevel ? Self.safariUIName(child.title) : child.title
                let path = prefix + [display]
                out.append((child, path.joined(separator: " / ")))
                walk(child, prefix: path, topLevel: false)
            }
        }
        walk(root, prefix: [], topLevel: true)
        return out
    }

    private func findFolder(under node: SafariBookmarkNode, uuid: String) -> SafariBookmarkNode? {
        for child in node.children where child.kind == .folder {
            if child.uuid == uuid { return child }
            if let found = findFolder(under: child, uuid: uuid) { return found }
        }
        return nil
    }

    /// Skips Apple's special lists (Reading List, Tab Group Favorites, …), which
    /// aren't real bookmark folders. Reading List is kept only when opted in.
    private func isExcludedTopLevel(_ node: SafariBookmarkNode, includeReadingList: Bool) -> Bool {
        if node.title == "com.apple.ReadingList" { return !includeReadingList }
        return node.title.hasPrefix("com.apple.")
    }

    /// Safari's own UI names for its two top-level lists (for the scope picker).
    static func safariUIName(_ title: String) -> String {
        switch title {
        case "BookmarksBar":  return "Favorites"
        case "BookmarksMenu": return "Bookmarks Menu"
        default:              return title
        }
    }

    /// The Chrome root a Safari top-level list mirrors into.
    static func chromeRootName(_ title: String) -> String {
        switch title {
        case "BookmarksBar":  return "Bookmarks Bar"
        case "BookmarksMenu": return "Other Bookmarks"
        default:              return title
        }
    }
}
