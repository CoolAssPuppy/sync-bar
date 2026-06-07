//
//  NotionSourceClient.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Notion as a source: a database's rows become notes, each row's `Category`
//  column becomes the destination folder (carried on `SourceItem.folderPath`).
//  The page's `last_edited_time` is the version hash, so the existing rules
//  engine skips unchanged pages and the ledger resumes where it left off. Read
//  plumbing lives in NotionPageReader; this type adapts it to `SourceClient` and
//  resolves the per-workspace token from Keychain.
//

import Foundation

struct NotionSourceClient: SourceClient {
    let kind: SourceKind = .notion

    /// Workspace context for `listScopes` (the database picker). The engine path
    /// reads the workspace from each call's `NotionSourceConfig` instead, so this
    /// is only set when the source-setup UI constructs the client for a workspace.
    private let workspaceId: String?
    private let keychain: KeychainStore
    private let session: URLSession

    init(workspaceId: String? = nil,
         keychain: KeychainStore = .shared,
         session: URLSession = .shared) {
        self.workspaceId = workspaceId
        self.keychain = keychain
        self.session = session
    }

    // MARK: Scopes (databases the user can back up)

    func listScopes() async throws -> [SourceScope] {
        guard let workspaceId else { return [] }
        let token = try token(for: workspaceId)
        let destinations = try await RealNotionClient(token: token, session: session)
            .listDestinations(workspaceId: workspaceId)
        return destinations
            .filter { $0.type == .database }
            .map { SourceScope(id: $0.id, name: $0.title, itemCount: 0) }
    }

    // MARK: Items (database rows)

    func listItems(config: SourceConfiguration) async throws -> [SourceItem] {
        let cfg = try notionConfig(config)
        let reader = NotionPageReader(token: try token(for: cfg.workspaceId), session: session)
        let pages = try await reader.queryPages(databaseId: cfg.databaseId,
                                                titleProperty: cfg.titleProperty,
                                                categoryProperty: cfg.categoryProperty)
        return pages.map { page in
            SourceItem(
                id: page.id,
                name: page.title,
                // last_edited_time is the change token: a re-edited page re-syncs,
                // an unchanged one is skipped by the rules engine.
                versionHash: Self.versionHash(page.lastEditedTime),
                createdAt: page.createdAt,
                tags: [],
                // The Category value is the destination folder/notebook; blank
                // categories fall back to the destination's configured folder.
                folderPath: page.category.map { [$0] } ?? []
            )
        }
    }

    func content(for item: SourceItem, config: SourceConfiguration) async throws -> NoteContent {
        let cfg = try notionConfig(config)
        let reader = NotionPageReader(token: try token(for: cfg.workspaceId), session: session)
        let blocks = try await reader.pageBlocks(pageId: item.id)
        return NoteContent(blocks: blocks, provider: "notion")
    }

    func resolveTitle(for item: SourceItem,
                      content: NoteContent,
                      config: SourceConfiguration,
                      strategyOverride: TitleStrategy?) -> String {
        item.name.isEmpty ? "Untitled" : item.name
    }

    func shouldSkipAsEmpty(content: NoteContent,
                           config: SourceConfiguration,
                           ocrModeOverride: OcrMode?) -> Bool {
        // A backup mirrors every page, including the empty ones.
        false
    }

    // MARK: Helpers

    /// A stable, comparable token for a page version. last_edited_time already
    /// changes on every edit; the ISO string is what we store and compare.
    static func versionHash(_ lastEdited: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: lastEdited)
    }

    private func notionConfig(_ config: SourceConfiguration) throws -> NotionSourceConfig {
        guard case .notion(let cfg) = config else {
            throw SourceError.wrongConfiguration(expected: .notion)
        }
        return cfg
    }

    private func token(for workspaceId: String) throws -> String {
        guard let token = keychain.value(for: .notionWorkspaceToken(workspaceId: workspaceId)),
              !token.isEmpty else {
            throw SourceError.unavailable("Reconnect the Notion workspace to back it up.")
        }
        return token
    }
}
