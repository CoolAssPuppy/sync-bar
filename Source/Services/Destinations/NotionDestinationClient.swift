//
//  NotionDestinationClient.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// Writes a transcribed page into Notion as either a child page (when the
/// destination is a Notion page) or a row (when it's a database).
///
/// If a Notion workspace access token is in `KeychainStore`, the client
/// calls the real Notion v2022-06-28 API. Without a token it falls back
/// to the deterministic mock so the UI is exercisable end-to-end.
struct NotionDestinationClient: DestinationClient {
    let kind: DestinationKind = .notion

    func write(payload: DestinationPayload, configuration: DestinationConfiguration) async throws -> DestinationWriteResult {
        guard case .notion(let config) = configuration else {
            throw DestinationError.wrongConfiguration(expected: .notion)
        }
        if let token = KeychainStore.shared.value(for: .notionWorkspaceToken(workspaceId: config.workspaceId)),
           !token.isEmpty {
            return try await writeWithRealNotion(token: token, config: config, payload: payload)
        }
        return try await writeWithMock(config: config, payload: payload)
    }

    // MARK: Real Notion (v2022-06-28)

    private func writeWithRealNotion(token: String, config: NotionDestinationConfig, payload: DestinationPayload) async throws -> DestinationWriteResult {
        let url = URL(string: "https://api.notion.com/v1/pages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var parent: [String: Any] = [:]
        var properties: [String: Any] = [:]
        switch config.destinationType {
        case .page:
            parent = ["page_id": config.destinationId]
            properties = ["title": ["title": [["text": ["content": payload.title]]]]]
        case .database:
            parent = ["database_id": config.destinationId]
            properties = ["Name": ["title": [["text": ["content": payload.title]]]]]
        }

        var children: [[String: Any]] = []
        for paragraph in payload.body.components(separatedBy: "\n\n") where !paragraph.isEmpty {
            children.append([
                "object": "block",
                "type": "paragraph",
                "paragraph": [
                    "rich_text": [["type": "text", "text": ["content": paragraph]]]
                ]
            ])
        }
        if let mermaid = payload.mermaidSource {
            children.append([
                "object": "block",
                "type": "code",
                "code": [
                    "language": "mermaid",
                    "rich_text": [["type": "text", "text": ["content": mermaid]]]
                ]
            ])
        }

        let body: [String: Any] = ["parent": parent, "properties": properties, "children": children]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 401, 403: throw NotionError.authorizationFailed
            case 429:      throw NotionError.rateLimited
            default:
                let snippet = String(data: data, encoding: .utf8)?.prefix(200).description ?? "HTTP \(http.statusCode)"
                throw NotionError.validationFailed(snippet)
            }
        }

        struct Page: Decodable { let id: String; let url: String }
        let parsed = try JSONDecoder().decode(Page.self, from: data)
        return DestinationWriteResult(externalId: parsed.id, externalURL: URL(string: parsed.url), notes: nil)
    }

    // MARK: Mock fallback

    private func writeWithMock(config: NotionDestinationConfig, payload: DestinationPayload) async throws -> DestinationWriteResult {
        try await Task.sleep(nanoseconds: 200_000_000)
        let id = "p-" + UUID().uuidString.prefix(10).lowercased()
        return DestinationWriteResult(
            externalId: id,
            externalURL: URL(string: "https://www.notion.so/preview/\(id)"),
            notes: "Mock Notion write (no token configured)."
        )
    }
}
