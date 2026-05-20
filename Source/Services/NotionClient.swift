//
//  NotionClient.swift
//  SyncBar
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

    /// Maps a non-2xx Notion response to a typed error, extracting the human
    /// `message` from Notion's error JSON ({"object":"error","code":…,
    /// "message":…}) instead of surfacing the raw body. Logs the full body for
    /// diagnosis. `context` labels the operation (e.g. "create page").
    static func from(status: Int, data: Data, context: String) -> NotionError {
        let body = String(data: data, encoding: .utf8) ?? ""
        Log.notion.error("\(context, privacy: .public) failed: HTTP \(status, privacy: .public) — \(body, privacy: .public)")
        switch status {
        case 401, 403: return .authorizationFailed
        case 429:      return .rateLimited
        default:       break
        }
        struct APIError: Decodable { let code: String?; let message: String? }
        if let parsed = try? JSONDecoder().decode(APIError.self, from: data),
           let message = parsed.message, !message.isEmpty {
            let code = parsed.code.map { " [\($0)]" } ?? ""
            return .validationFailed("Notion: \(message)\(code)")
        }
        let snippet = body.isEmpty ? "HTTP \(status)" : String(body.prefix(300))
        return .validationFailed("Notion HTTP \(status): \(snippet)")
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
