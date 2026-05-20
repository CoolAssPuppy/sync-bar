//
//  LinearDestinationClient.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// Creates an issue in Linear from a transcribed reMarkable page. Uses
/// Linear's GraphQL endpoint when a token exists, otherwise the mock.
struct LinearDestinationClient: DestinationClient {
    let kind: DestinationKind = .linear

    func write(payload: DestinationPayload, configuration: DestinationConfiguration) async throws -> DestinationWriteResult {
        guard case .linear(let config) = configuration else {
            throw DestinationError.wrongConfiguration(expected: .linear)
        }
        if let token = KeychainStore.shared.value(for: .linearAccessToken),
           !token.isEmpty {
            return try await writeWithRealLinear(token: token, config: config, payload: payload)
        }
        return try await writeWithMock(config: config, payload: payload)
    }

    // MARK: Real Linear (GraphQL)

    private func writeWithRealLinear(token: String, config: LinearDestinationConfig, payload: DestinationPayload) async throws -> DestinationWriteResult {
        let body = payload.body + (payload.mermaidSource.map { "\n\n```mermaid\n\($0)\n```" } ?? "")
        let mutation = """
        mutation IssueCreate($teamId: String!, $title: String!, $description: String!, $projectId: String, $labelIds: [String!]) {
            issueCreate(input: { teamId: $teamId, title: $title, description: $description, projectId: $projectId, labelIds: $labelIds }) {
                success
                issue { id identifier url }
            }
        }
        """
        var variables: [String: Any] = [
            "teamId": config.workspaceId,
            "title": payload.title,
            "description": body
        ]
        if let projectId = config.projectId, !projectId.isEmpty { variables["projectId"] = projectId }

        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": mutation, "variables": variables])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 401, 403: throw DestinationError.apiFailed(status: http.statusCode, snippet: "Linear rejected the token.")
            case 429:      throw DestinationError.rateLimited
            default:
                let snippet = String(data: data, encoding: .utf8)?.prefix(200).description ?? "HTTP \(http.statusCode)"
                throw DestinationError.apiFailed(status: http.statusCode, snippet: snippet)
            }
        }

        struct Response: Decodable {
            struct Wrapper: Decodable { struct IssueCreate: Decodable { struct Issue: Decodable { let id: String; let identifier: String; let url: String }; let issue: Issue? }; let issueCreate: IssueCreate }
            let data: Wrapper?
        }
        let parsed = try JSONDecoder().decode(Response.self, from: data)
        guard let issue = parsed.data?.issueCreate.issue else {
            throw DestinationError.apiFailed(status: 200, snippet: "Linear issueCreate returned no issue")
        }
        return DestinationWriteResult(externalId: issue.id, externalURL: URL(string: issue.url), notes: issue.identifier)
    }

    // MARK: Mock fallback

    private func writeWithMock(config: LinearDestinationConfig, payload: DestinationPayload) async throws -> DestinationWriteResult {
        try await Task.sleep(nanoseconds: 180_000_000)
        let id = "ENG-" + String(Int.random(in: 100...9_999))
        return DestinationWriteResult(
            externalId: id,
            externalURL: URL(string: "https://linear.app/preview/issue/\(id)"),
            notes: id + " (mock issue, no token configured)"
        )
    }
}
