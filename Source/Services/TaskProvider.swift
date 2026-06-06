//
//  TaskProvider.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The provider-agnostic seam for two-way task sync. The merge engine already
//  works on the neutral CanonicalTask; this abstracts the "other side" (Notion
//  today, Todoist or others later) behind one protocol + a polymorphic config,
//  mirroring how Sources and Destinations are modeled. Adding a tracker = a new
//  TaskProviderKind, a config case, and a TaskProvider conformer.
//

import Foundation

/// One task on the remote side, projected to the neutral shape plus what the
/// merge needs: a stable id, last-edited time (the conflict tiebreak), whether
/// it's been removed/archived, and its raw status (for filter rules).
struct RemoteTask: Equatable, Hashable, Sendable {
    var id: String
    var task: CanonicalTask
    var lastEditedTime: Date
    var archived: Bool
    var rawStatus: String? = nil
    /// The row's category-column option name, for lane scoping. nil when the sync
    /// has no category column or the row's column is empty (an uncategorized row).
    var categoryValue: String? = nil
}

/// Which task tracker the Notion-side of a sync points at. Notion is the only
/// one today; the type exists so the editor and config can grow others.
enum TaskProviderKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case notion

    var id: String { rawValue }
    var label: String {
        switch self {
        case .notion: return "Notion"
        }
    }
    var assetName: String {
        switch self {
        case .notion: return "Destinations/Notion"
        }
    }
}

/// Notion specifics: which workspace + database, and how its columns map.
struct NotionTaskConfig: Codable, Equatable, Hashable, Sendable {
    var workspaceId: String
    var databaseId: String
    var databaseName: String
    var fieldMapping: TaskFieldMapping
}

/// The polymorphic remote-side configuration of a two-way sync. One case per
/// TaskProviderKind, like DestinationConfiguration.
enum TaskProviderConfig: Codable, Equatable, Hashable, Sendable {
    case notion(NotionTaskConfig)

    var kind: TaskProviderKind {
        switch self {
        case .notion: return .notion
        }
    }

    /// The user-facing name of the target (the Notion database).
    var displayName: String {
        switch self {
        case .notion(let config): return config.databaseName
        }
    }

    var fieldMapping: TaskFieldMapping {
        switch self {
        case .notion(let config): return config.fieldMapping
        }
    }

    /// The Notion config when this is a Notion provider (the editor's typed access).
    var notionConfig: NotionTaskConfig? {
        if case .notion(let config) = self { return config }
        return nil
    }
}

/// The remote half of a two-way TaskSync. Reads and writes tasks, configured for
/// one target. A protocol so the coordinator's tests can substitute a stub and
/// so new trackers slot in without touching the engine.
protocol TaskProvider: Sendable {
    func fetchTasks() async throws -> [RemoteTask]
    /// Creates a task and returns its new stable id.
    func createTask(_ task: CanonicalTask) async throws -> String
    func updateTask(id: String, to task: CanonicalTask) async throws
    /// Removes the task from the remote side (archive for Notion).
    func removeTask(id: String) async throws
}

/// Builds the right provider for a config, or nil when it can't run (e.g. no
/// stored token). The single place the coordinator branches on provider kind.
enum TaskProviderRouter {
    @MainActor
    static func make(config: TaskProviderConfig, keychain: KeychainStore = .shared) -> TaskProvider? {
        switch config {
        case .notion(let notion):
            guard let token = keychain.value(for: .notionWorkspaceToken(workspaceId: notion.workspaceId)),
                  !token.isEmpty else { return nil }
            return RealNotionTaskClient(token: token, config: notion)
        }
    }
}
