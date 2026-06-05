//
//  SafariSourceClient.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// The second `SourceClient`: Safari bookmarks (read-only). Reads
/// `~/Library/Safari/Bookmarks.plist` via `SafariBookmarkReader` and presents
/// folders as scopes and bookmarks as items. There is no document content and
/// no OCR; a bookmark's payload is just its URL + title.
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
        let scopeNode = (cfg.folderId == SafariSourceConfig.allScopeId)
            ? root
            : findFolder(under: root, uuid: cfg.folderId)
        guard let scopeNode else { return [] }

        return leaves(under: scopeNode, includeReadingList: cfg.includeReadingList).compactMap { leaf in
            guard case .leaf(let url) = leaf.kind else { return nil }
            return SourceItem(
                id: leaf.uuid,
                name: leaf.title,
                // A change to either the URL or the title re-syncs the bookmark.
                versionHash: "\(url)\u{1}\(leaf.title)",
                createdAt: .distantPast,   // Safari leaves carry no reliable date
                tags: [],
                url: URL(string: url)
            )
        }
    }

    /// A bookmark has no document content; the URL travels on the SourceItem.
    func content(for item: SourceItem, config: SourceConfiguration) async throws -> NoteContent {
        NoteContent(blocks: [])
    }

    /// reMarkable title strategies don't apply; use the bookmark's own title,
    /// falling back to its host.
    func resolveTitle(for item: SourceItem,
                      content: NoteContent,
                      config: SourceConfiguration,
                      strategyOverride: TitleStrategy?) -> String {
        if !item.name.isEmpty { return item.name }
        return item.url?.host ?? item.url?.absoluteString ?? "Untitled bookmark"
    }

    /// A bookmark is never "empty".
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

    /// Every leaf bookmark under a node, recursively. The Reading List subtree
    /// is excluded unless `includeReadingList`.
    private func leaves(under node: SafariBookmarkNode, includeReadingList: Bool) -> [SafariBookmarkNode] {
        var out: [SafariBookmarkNode] = []
        func walk(_ n: SafariBookmarkNode) {
            for child in n.children {
                switch child.kind {
                case .leaf:
                    out.append(child)
                case .folder:
                    if child.isReadingList && !includeReadingList { continue }
                    walk(child)
                }
            }
        }
        walk(node)
        return out
    }

    /// Every folder under a node, recursively, with a " / "-joined path name.
    /// The Reading List subtree is skipped.
    private func folders(under root: SafariBookmarkNode) -> [(node: SafariBookmarkNode, name: String)] {
        var out: [(node: SafariBookmarkNode, name: String)] = []
        func walk(_ node: SafariBookmarkNode, prefix: [String]) {
            for child in node.children where child.kind == .folder {
                if child.isReadingList { continue }
                let path = prefix + [Self.displayName(child.title)]
                out.append((child, path.joined(separator: " / ")))
                walk(child, prefix: path)
            }
        }
        walk(root, prefix: [])
        return out
    }

    private func findFolder(under node: SafariBookmarkNode, uuid: String) -> SafariBookmarkNode? {
        for child in node.children where child.kind == .folder {
            if child.uuid == uuid { return child }
            if let found = findFolder(under: child, uuid: uuid) { return found }
        }
        return nil
    }

    /// Maps Safari's internal folder names to user-facing ones.
    static func displayName(_ title: String) -> String {
        switch title {
        case "BookmarksBar":  return "Bookmarks Bar"
        case "BookmarksMenu": return "Bookmarks Menu"
        default:              return title
        }
    }
}
