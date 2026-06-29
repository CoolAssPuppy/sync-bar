//
//  XAuthService.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  X (Twitter) OAuth 2.0 with PKCE. X mandates PKCE and (for `offline.access`)
//  issues a rotating refresh token, so this mirrors the Google flow: an
//  interactive connect on the main actor, plus a non-isolated `XTokens` that
//  exchanges, stores, and refreshes tokens off the main actor before each sync.
//
//  Only the scopes the chosen content streams need are requested, so a user who
//  syncs only their posts never grants bookmark.read / like.read.
//

import Foundation

/// Decoded X token endpoint response.
struct XTokenResponse: Decodable, Sendable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
    let scope: String?
    let token_type: String?
}

/// The authenticated X user, from `/2/users/me`.
struct XMe: Equatable, Sendable {
    let id: String
    let username: String
    let name: String
}

/// Non-isolated token exchange, storage, and refresh.
enum XTokens {
    static let tokenURL = URL(staticString: "https://api.twitter.com/2/oauth2/token")
    static let meURL = URL(staticString: "https://api.twitter.com/2/users/me")

    static func parseTokenResponse(_ data: Data) throws -> XTokenResponse {
        let parsed = try JSONDecoder().decode(XTokenResponse.self, from: data)
        guard !parsed.access_token.isEmpty else {
            throw OAuthError.invalidResponse("X returned an empty access token.")
        }
        return parsed
    }

    static func exchangeCode(code: String, verifier: String, redirectURI: String,
                             session: URLSession = .shared) async throws -> XTokenResponse {
        let body = OAuth.formURLEncoded([
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
            "client_id": AuthSecrets.xClientId
        ])
        return try await post(body: body, context: "X token exchange", session: session)
    }

    static func store(accountId: String, response: XTokenResponse, keychain: KeychainStore = .shared) {
        keychain.set(value: response.access_token, for: .xAccessToken(accountId: accountId))
        // X rotates the refresh token on every refresh; persist the new one so
        // the next refresh doesn't reuse a spent token. Absent on non-offline
        // grants — leave the stored one alone then.
        if let refresh = response.refresh_token, !refresh.isEmpty {
            keychain.set(value: refresh, for: .xRefreshToken(accountId: accountId))
        }
        let expiry = Date().timeIntervalSince1970 + Double(response.expires_in ?? 7200)
        keychain.set(value: String(expiry), for: .xTokenExpiry(accountId: accountId))
    }

    /// A non-expired access token, refreshing when within a minute of expiry.
    static func validAccessToken(accountId: String, keychain: KeychainStore = .shared,
                                 session: URLSession = .shared) async throws -> String {
        let now = Date().timeIntervalSince1970
        if let access = keychain.value(for: .xAccessToken(accountId: accountId)), !access.isEmpty,
           let expiryString = keychain.value(for: .xTokenExpiry(accountId: accountId)),
           let expiry = Double(expiryString), now < expiry - 60 {
            return access
        }
        return try await refresh(accountId: accountId, keychain: keychain, session: session)
    }

    static func refresh(accountId: String, keychain: KeychainStore = .shared,
                        session: URLSession = .shared) async throws -> String {
        guard AuthSecrets.isXConfigured else { throw OAuthError.notConfigured(provider: "Twitter") }
        guard let refreshToken = keychain.value(for: .xRefreshToken(accountId: accountId)), !refreshToken.isEmpty else {
            throw OAuthError.tokenExchangeFailed("X sign-in has expired. Reconnect the account.")
        }
        let body = OAuth.formURLEncoded([
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
            "client_id": AuthSecrets.xClientId
        ])
        let response = try await post(body: body, context: "X token refresh", session: session)
        store(accountId: accountId, response: response, keychain: keychain)
        return response.access_token
    }

    /// Looks up the authenticated user so a connection can be keyed by user id
    /// and labeled with the @handle.
    static func fetchMe(accessToken: String, session: URLSession = .shared) async throws -> XMe {
        var components = URLComponents(url: meURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.queryItems = [URLQueryItem(name: "user.fields", value: "username,name")]
        var request = URLRequest(url: components.url ?? meURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response, data, context: "X account lookup")
        struct MeResponse: Decodable { struct User: Decodable { let id: String; let username: String; let name: String }; let data: User? }
        guard let user = (try? JSONDecoder().decode(MeResponse.self, from: data))?.data, !user.id.isEmpty else {
            throw OAuthError.invalidResponse("X didn't return the connected account.")
        }
        return XMe(id: user.id, username: user.username, name: user.name)
    }

    private static func post(body: Data, context: String, session: URLSession) async throws -> XTokenResponse {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Confidential clients authenticate with HTTP Basic (client_id:secret);
        // public (PKCE-only) clients send just the client_id in the body.
        if !AuthSecrets.xClientSecret.isEmpty {
            let credentials = Data("\(AuthSecrets.xClientId):\(AuthSecrets.xClientSecret)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try validate(response, data, context: context)
        return try parseTokenResponse(data)
    }

    private static func validate(_ response: URLResponse, _ data: Data, context: String) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        if http.statusCode == 401 { throw OAuthError.tokenExchangeFailed("X sign-in has expired. Reconnect the account.") }
        let snippet = String(data: data, encoding: .utf8)?.prefix(200).description ?? "HTTP \(http.statusCode)"
        throw OAuthError.tokenExchangeFailed("\(context) failed (HTTP \(http.statusCode)): \(snippet)")
    }
}

/// Interactive X connect flow (main-actor; drives the web auth session).
@MainActor
final class XAuthService {
    static let shared = XAuthService()

    private let keychain: KeychainStore

    init(keychain: KeychainStore = .shared) {
        self.keychain = keychain
    }

    static let provider = "x"
    static var redirectURI: String { OAuth.redirectURI(provider: provider) }

    private static let authorizeBase = URL(staticString: "https://twitter.com/i/oauth2/authorize")

    /// The space-separated scope string for a set of streams. Always includes the
    /// baseline read scopes plus `offline.access` (so a refresh token is issued),
    /// then the minimal per-stream scopes, deduped and in a stable order.
    static func scopes(for streams: [XStream]) -> String {
        var ordered: [String] = ["tweet.read", "users.read", "offline.access"]
        var seen = Set(ordered)
        for stream in streams {
            guard let scope = stream.requiredScope, seen.insert(scope).inserted else { continue }
            ordered.append(scope)
        }
        return ordered.joined(separator: " ")
    }

    static func authorizeURL(clientId: String, state: String, challenge: String, scope: String) -> URL {
        var components = URLComponents(url: authorizeBase, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components.url ?? authorizeBase
    }

    /// Runs the OAuth flow for the chosen streams and returns the connected
    /// account. Tokens are stored in the keychain keyed by the X user id.
    @discardableResult
    func connect(streams: [XStream]) async throws -> XAccount {
        guard AuthSecrets.isXConfigured else { throw OAuthError.notConfigured(provider: "Twitter") }
        let streams = streams.isEmpty ? XStream.allCases : streams

        let state = OAuth.randomState()
        let verifier = OAuth.pkceVerifier()
        let challenge = OAuth.pkceChallenge(for: verifier)
        let scope = Self.scopes(for: streams)
        let authorizeURL = Self.authorizeURL(clientId: AuthSecrets.xClientId, state: state, challenge: challenge, scope: scope)

        let callback = try await OAuthWebSession().start(
            authorizeURL: authorizeURL,
            callbackURLScheme: OAuth.callbackScheme
        )
        guard OAuth.queryValue("state", from: callback) == state else { throw OAuthError.stateMismatch }
        if let error = OAuth.queryValue("error", from: callback) {
            throw OAuthError.tokenExchangeFailed("X declined the connection: \(error)")
        }
        guard let code = OAuth.queryValue("code", from: callback) else { throw OAuthError.missingAuthorizationCode }

        let token = try await XTokens.exchangeCode(code: code, verifier: verifier, redirectURI: Self.redirectURI)
        let me = try await XTokens.fetchMe(accessToken: token.access_token)
        XTokens.store(accountId: me.id, response: token, keychain: keychain)
        return XAccount(id: me.id, username: me.username, displayName: me.name,
                        connectedAt: Date(), selectedStreams: streams)
    }
}
