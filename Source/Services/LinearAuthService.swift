//
//  LinearAuthService.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// Drives the Linear OAuth connect flow: open the authorize page, exchange the
/// returned code for an access token, store it in the keychain, and fetch the
/// teams the token can reach so each becomes a bindable destination.
///
/// Linear issues long-lived access tokens (years) and no refresh token, so
/// there is no refresh path; a revoked token is fixed by reconnecting.
@MainActor
final class LinearAuthService {
    static let shared = LinearAuthService()

    private let keychain: KeychainStore
    private let session: URLSession

    init(keychain: KeychainStore = .shared, session: URLSession = .shared) {
        self.keychain = keychain
        self.session = session
    }

    static let provider = "linear"
    static var redirectURI: String { OAuth.redirectURI(provider: provider) }

    private static let authorizeBase = "https://linear.app/oauth/authorize"
    private static let tokenURL = URL(string: "https://api.linear.app/oauth/token")!
    private static let graphqlURL = URL(string: "https://api.linear.app/graphql")!
    private static let scopes = "read,write"

    // MARK: Pure helpers (unit-tested)

    static func authorizeURL(clientId: String, state: String) -> URL {
        var components = URLComponents(string: authorizeBase)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "actor", value: "user")
        ]
        return components.url!
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let token_type: String?
        let expires_in: Int?
        let scope: String?
    }

    static func parseAccessToken(_ data: Data) throws -> String {
        let token = try JSONDecoder().decode(TokenResponse.self, from: data).access_token
        guard !token.isEmpty else { throw OAuthError.invalidResponse("Linear returned an empty access token.") }
        return token
    }

    private struct TeamsResponse: Decodable {
        struct DataField: Decodable {
            struct Viewer: Decodable {
                struct Organization: Decodable { let name: String }
                let organization: Organization?
            }
            struct Teams: Decodable {
                struct Node: Decodable { let id: String; let name: String }
                let nodes: [Node]
            }
            let viewer: Viewer?
            let teams: Teams
        }
        let data: DataField?
    }

    static func parseTeams(_ data: Data, connectedAt: Date = Date()) throws -> [LinearAccount] {
        let parsed = try JSONDecoder().decode(TeamsResponse.self, from: data)
        guard let field = parsed.data else {
            throw OAuthError.invalidResponse("Linear returned no team data.")
        }
        let org = field.viewer?.organization?.name ?? "Linear"
        return field.teams.nodes.map {
            LinearAccount(id: $0.id, name: $0.name, organizationName: org, connectedAt: connectedAt)
        }
    }

    // MARK: Flow

    @discardableResult
    func connect() async throws -> [LinearAccount] {
        guard AuthSecrets.isLinearConfigured else { throw OAuthError.notConfigured(provider: "Linear") }

        let state = OAuth.randomState()
        let authorizeURL = Self.authorizeURL(clientId: AuthSecrets.linearClientId, state: state)
        let callback = try await OAuthWebSession().start(
            authorizeURL: authorizeURL,
            callbackURLScheme: OAuth.callbackScheme
        )
        guard OAuth.queryValue("state", from: callback) == state else { throw OAuthError.stateMismatch }
        guard let code = OAuth.queryValue("code", from: callback) else { throw OAuthError.missingAuthorizationCode }

        let token = try await exchangeCodeForToken(code)
        keychain.set(value: token, for: .linearAccessToken)

        let teams = try await fetchTeams(token: token)
        guard !teams.isEmpty else {
            throw OAuthError.invalidResponse("Your Linear account has no teams to sync into.")
        }
        return teams
    }

    private func exchangeCodeForToken(_ code: String) async throws -> String {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OAuth.formURLEncoded([
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": AuthSecrets.linearClientId,
            "client_secret": AuthSecrets.linearClientSecret,
            "grant_type": "authorization_code"
        ])
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data, context: "Linear token exchange")
        return try Self.parseAccessToken(data)
    }

    private func fetchTeams(token: String) async throws -> [LinearAccount] {
        let query = "{ viewer { organization { name } } teams { nodes { id name } } }"
        var request = URLRequest(url: Self.graphqlURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data, context: "Linear team lookup")
        return try Self.parseTeams(data)
    }

    private static func validate(_ response: URLResponse, _ data: Data, context: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? "HTTP \(http.statusCode)"
            throw OAuthError.tokenExchangeFailed("\(context) failed (HTTP \(http.statusCode)): \(snippet)")
        }
    }
}
