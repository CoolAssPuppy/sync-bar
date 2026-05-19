//
//  RealNotionClient.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Notion API v2022-06-28 client used for catalog operations:
//    • Search for pages and databases the integration can see.
//    • Retrieve database schema.
//
//  Writing into Notion is handled by NotionDestinationClient. This file
//  exists so that the rules sheet can refresh its dropdowns against a
//  real Notion workspace once an OAuth token is stored in Keychain.
//

import Foundation

/// Returns the real Notion client when a workspace token is in Keychain,
/// the mock otherwise. Lets the binding editor and the sync coordinator
/// stay client-agnostic.
enum NotionClientFactory {
    static func make(workspaceId: String?, keychain: KeychainStore = .shared) -> NotionClient {
        if let workspaceId,
           let token = keychain.value(for: .notionWorkspaceToken(workspaceId: workspaceId)),
           !token.isEmpty {
            return RealNotionClient(token: token)
        }
        return MockNotionClient()
    }
}

struct RealNotionClient: NotionClient {
    let token: String
    private let session: URLSession

    init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    func connectMockWorkspace(label: String) async throws -> NotionWorkspace {
        // Real OAuth is brokered in NotionOAuth.swift; this entry point is
        // unused on the real path.
        throw NotionError.authorizationFailed
    }

    func listDestinations(workspaceId: String) async throws -> [NotionDestination] {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/search")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "query": "",
            "page_size": 50,
            "sort": ["direction": "descending", "timestamp": "last_edited_time"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)

        struct SearchResponse: Decodable {
            struct Item: Decodable {
                struct Title: Decodable { struct Inner: Decodable { let plain_text: String? }; let title: [Inner]? }
                struct PropertiesContainer: Decodable { let title: Title? }
                struct Parent: Decodable { let type: String? }
                struct Icon: Decodable { let emoji: String? }
                let id: String
                let object: String  // "page" or "database"
                let properties: PropertiesContainer?
                let parent: Parent?
                let icon: Icon?
                let title: [Title.Inner]?  // databases ship their title at the top level
            }
            let results: [Item]
        }
        let parsed = try JSONDecoder().decode(SearchResponse.self, from: data)
        return parsed.results.map { item -> NotionDestination in
            let extractedTitle: String = {
                if let dbTitle = item.title?.compactMap(\.plain_text).joined(), !dbTitle.isEmpty {
                    return dbTitle
                }
                if let pageTitle = item.properties?.title?.title?.compactMap(\.plain_text).joined(),
                   !pageTitle.isEmpty {
                    return pageTitle
                }
                return "Untitled"
            }()
            return NotionDestination(
                id: item.id,
                type: item.object == "database" ? .database : .page,
                title: extractedTitle,
                icon: item.icon?.emoji,
                parentPath: item.parent?.type
            )
        }
    }

    func databaseSchema(destinationId: String, workspaceId: String) async throws -> [NotionDatabaseProperty] {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/databases/\(destinationId)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)

        struct DBResponse: Decodable {
            struct Property: Decodable {
                struct Option: Decodable { let name: String }
                struct OptionContainer: Decodable { let options: [Option] }
                let name: String
                let type: String
                let select: OptionContainer?
                let multi_select: OptionContainer?
                let status: OptionContainer?
            }
            let properties: [String: Property]
        }
        let parsed = try JSONDecoder().decode(DBResponse.self, from: data)
        return parsed.properties.map { (key, prop) -> NotionDatabaseProperty in
            let options = (prop.select?.options ?? prop.multi_select?.options ?? prop.status?.options ?? []).map(\.name)
            return NotionDatabaseProperty(name: key, type: prop.type, options: options)
        }
    }

    func createPage(workspaceId: String, destinationId: String, title: String) async throws -> NotionPageWriteResult {
        // The real write path lives in NotionDestinationClient. This entry
        // exists to satisfy the NotionClient protocol (used for previews and
        // legacy tests). It writes a minimal page.
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/pages")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "parent": ["page_id": destinationId],
            "properties": ["title": ["title": [["text": ["content": title]]]]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        struct PageResp: Decodable { let id: String; let url: String }
        let parsed = try JSONDecoder().decode(PageResp.self, from: data)
        return NotionPageWriteResult(id: parsed.id, url: parsed.url)
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw NotionError.authorizationFailed
        case 429:      throw NotionError.rateLimited
        default:
            let snippet = String(data: data, encoding: .utf8)?.prefix(200).description ?? "HTTP \(http.statusCode)"
            throw NotionError.validationFailed(snippet)
        }
    }
}

