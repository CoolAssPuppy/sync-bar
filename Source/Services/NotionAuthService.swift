//
//  NotionAuthService.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation
import AppKit

/// Drives the Notion OAuth connect flow. Notion rejects custom URL schemes and
/// requires an http(s) redirect, so the flow opens the system browser and
/// captures the redirect with a loopback HTTP listener on a fixed port. The
/// token endpoint authenticates the client with HTTP Basic (client_id:secret).
@MainActor
final class NotionAuthService {
    static let shared = NotionAuthService()

    private let keychain: KeychainStore
    private let session: URLSession

    init(keychain: KeychainStore = .shared, session: URLSession = .shared) {
        self.keychain = keychain
        self.session = session
    }

    /// Fixed loopback port. The user must register the matching redirect URI
    /// in their Notion integration (see the README).
    static let loopbackPort: UInt16 = 53117
    static var redirectURI: String { "http://localhost:\(loopbackPort)/oauth/notion" }

    private static let authorizeBase = URL(staticString: "https://api.notion.com/v1/oauth/authorize")
    private static let tokenURL = URL(staticString: "https://api.notion.com/v1/oauth/token")
    private static let notionVersion = "2022-06-28"

    // MARK: Pure helpers (unit-tested)

    static func authorizeURL(clientId: String, state: String) -> URL {
        var components = URLComponents(url: authorizeBase, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "owner", value: "user"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url ?? authorizeBase
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let workspace_id: String
        let workspace_name: String?
        let workspace_icon: String?
        let bot_id: String?
    }

    static func parseWorkspace(_ data: Data, connectedAt: Date = Date()) throws -> (workspace: NotionWorkspace, accessToken: String) {
        let parsed = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard !parsed.access_token.isEmpty, !parsed.workspace_id.isEmpty else {
            throw OAuthError.invalidResponse("Notion returned an incomplete token response.")
        }
        let workspace = NotionWorkspace(
            id: parsed.workspace_id,
            workspaceName: parsed.workspace_name ?? "Notion workspace",
            workspaceIcon: parsed.workspace_icon,
            botId: parsed.bot_id ?? "",
            connectedAt: connectedAt,
            lastCatalogRefreshAt: nil
        )
        return (workspace, parsed.access_token)
    }

    // MARK: Flow

    @discardableResult
    func connect() async throws -> NotionWorkspace {
        guard AuthSecrets.isNotionConfigured else { throw OAuthError.notConfigured(provider: "Notion") }

        let state = OAuth.randomState()
        let authorizeURL = Self.authorizeURL(clientId: AuthSecrets.notionClientId, state: state)

        let server = LoopbackOAuthServer()
        async let callback = server.waitForCallback(port: Self.loopbackPort)
        NSWorkspace.shared.open(authorizeURL)
        let items = try await callback

        guard items["state"] == state else { throw OAuthError.stateMismatch }
        if let error = items["error"] {
            throw OAuthError.tokenExchangeFailed("Notion declined the connection: \(error)")
        }
        guard let code = items["code"] else { throw OAuthError.missingAuthorizationCode }

        let result = try await exchangeCodeForToken(code)
        keychain.set(value: result.accessToken, for: .notionWorkspaceToken(workspaceId: result.workspace.id))
        return result.workspace
    }

    private func exchangeCodeForToken(_ code: String) async throws -> (workspace: NotionWorkspace, accessToken: String) {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        let credentials = Data("\(AuthSecrets.notionClientId):\(AuthSecrets.notionClientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.notionVersion, forHTTPHeaderField: "Notion-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI
        ])

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? "HTTP \(http.statusCode)"
            throw OAuthError.tokenExchangeFailed("Notion token exchange failed (HTTP \(http.statusCode)): \(snippet)")
        }
        return try Self.parseWorkspace(data)
    }
}
