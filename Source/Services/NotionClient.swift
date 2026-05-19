//
//  NotionClient.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

enum NotionError: LocalizedError, Sendable {
    case authorizationFailed
    case rateLimited
    case validationFailed(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .authorizationFailed: return "Notion turned us away. Reconnect the workspace."
        case .rateLimited:         return "Notion is throttling us. Try again in a minute."
        case .validationFailed(let msg): return msg
        case .network(let msg):    return msg
        }
    }
}

struct NotionPageWriteResult: Sendable {
    let id: String
    let url: String
}

protocol NotionClient: Sendable {
    func listDestinations(workspaceId: String) async throws -> [NotionDestination]
    func databaseSchema(destinationId: String, workspaceId: String) async throws -> [NotionDatabaseProperty]
    func createPage(workspaceId: String, destinationId: String, title: String) async throws -> NotionPageWriteResult
}

/// Deterministic mock client. Used everywhere until real OAuth wiring lands.
struct MockNotionClient: NotionClient {
    private static let presetDestinations: [String: [NotionDestination]] = [
        "default": [
            NotionDestination(id: "page-notes", type: .page, title: "Notes", icon: "📓", parentPath: "Private"),
            NotionDestination(id: "page-meetings", type: .page, title: "Meetings", icon: "📒", parentPath: "Private"),
            NotionDestination(id: "page-journal", type: .page, title: "Daily journal", icon: "📔", parentPath: "Personal"),
            NotionDestination(id: "db-tasks", type: .database, title: "Tasks", icon: "✅", parentPath: "Private"),
            NotionDestination(id: "db-research", type: .database, title: "Research", icon: "🔬", parentPath: "Work")
        ]
    ]

    private static let presetSchema: [String: [NotionDatabaseProperty]] = [
        "db-tasks": [
            NotionDatabaseProperty(name: "Status", type: "status", options: ["Backlog", "In progress", "Done"]),
            NotionDatabaseProperty(name: "Priority", type: "select", options: ["Low", "Medium", "High"]),
            NotionDatabaseProperty(name: "Tags", type: "multi_select", options: ["Engineering", "Design", "Product"]),
            NotionDatabaseProperty(name: "Due", type: "date", options: [])
        ],
        "db-research": [
            NotionDatabaseProperty(name: "Phase", type: "select", options: ["Discovery", "Synthesis", "Recommendation"]),
            NotionDatabaseProperty(name: "Topics", type: "multi_select", options: ["Onboarding", "Pricing", "Retention", "Mobile"]),
            NotionDatabaseProperty(name: "Reviewed", type: "checkbox", options: []),
            NotionDatabaseProperty(name: "Captured", type: "date", options: [])
        ]
    ]

    func connectMockWorkspace(label: String) async throws -> NotionWorkspace {
        try await Task.sleep(nanoseconds: 500_000_000)
        let id = "ws-" + UUID().uuidString.prefix(8).lowercased()
        return NotionWorkspace(
            id: id,
            workspaceName: label.isEmpty ? "Personal" : label,
            workspaceIcon: ["🪐", "🛰", "🌌", "📡"].randomElement(),
            botId: "bot-\(id)",
            connectedAt: Date(),
            lastCatalogRefreshAt: Date()
        )
    }

    func listDestinations(workspaceId: String) async throws -> [NotionDestination] {
        try await Task.sleep(nanoseconds: 200_000_000)
        return Self.presetDestinations["default", default: []]
    }

    func databaseSchema(destinationId: String, workspaceId: String) async throws -> [NotionDatabaseProperty] {
        try await Task.sleep(nanoseconds: 150_000_000)
        return Self.presetSchema[destinationId, default: []]
    }

    func createPage(workspaceId: String, destinationId: String, title: String) async throws -> NotionPageWriteResult {
        try await Task.sleep(nanoseconds: 200_000_000)
        let id = "p-" + UUID().uuidString.prefix(10).lowercased()
        return NotionPageWriteResult(id: id, url: "https://www.notion.so/preview/\(id)")
    }
}
