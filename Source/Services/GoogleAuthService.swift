//
//  GoogleAuthService.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Google OAuth for an installed/desktop app: PKCE + a loopback redirect
//  (Google rejects custom URL schemes). The interactive connect runs on the
//  main actor (it drives the browser + loopback listener); token exchange and
//  the hourly refresh live in `GoogleTokens`, which is non-isolated so the sync
//  engine can mint a fresh access token off the main actor before each write.
//

import Foundation
import AppKit

/// A Google Drive folder the user can target.
struct GoogleDriveFolder: Identifiable, Decodable, Equatable {
    let id: String
    let name: String
}

/// Decoded Google token endpoint response.
struct GoogleTokenResponse: Decodable {
    let access_token: String
    let expires_in: Int?
    let refresh_token: String?
    let scope: String?
    let token_type: String?
}

/// Non-isolated token exchange, storage, and refresh.
enum GoogleTokens {
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let userInfoURL = URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!

    static func parseTokenResponse(_ data: Data) throws -> GoogleTokenResponse {
        let parsed = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
        guard !parsed.access_token.isEmpty else {
            throw OAuthError.invalidResponse("Google returned an empty access token.")
        }
        return parsed
    }

    static func exchangeCode(code: String, verifier: String, redirectURI: String,
                             session: URLSession = .shared) async throws -> GoogleTokenResponse {
        let body = OAuth.formURLEncoded([
            "code": code,
            "client_id": AuthSecrets.googleClientId,
            "client_secret": AuthSecrets.googleClientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier
        ])
        return try await post(body: body, context: "Google token exchange", session: session)
    }

    /// Lists the account's Drive folders so a destination can target one.
    /// Requires the drive.metadata.readonly scope.
    static func listFolders(email: String, session: URLSession = .shared) async throws -> [GoogleDriveFolder] {
        let token = try await validAccessToken(email: email, session: session)
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "mimeType = 'application/vnd.google-apps.folder' and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "pageSize", value: "200"),
            URLQueryItem(name: "orderBy", value: "name")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? "HTTP \(http.statusCode)"
            throw OAuthError.invalidResponse("Drive folder list failed (HTTP \(http.statusCode)): \(snippet)")
        }
        struct FolderList: Decodable { let files: [GoogleDriveFolder] }
        return (try? JSONDecoder().decode(FolderList.self, from: data))?.files ?? []
    }

    static func fetchEmail(accessToken: String, session: URLSession = .shared) async throws -> String {
        var request = URLRequest(url: userInfoURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response, data, context: "Google userinfo")
        struct UserInfo: Decodable { let email: String? }
        guard let email = (try? JSONDecoder().decode(UserInfo.self, from: data))?.email, !email.isEmpty else {
            throw OAuthError.invalidResponse("Google didn't return an account email.")
        }
        return email
    }

    static func store(email: String, response: GoogleTokenResponse, keychain: KeychainStore = .shared) {
        keychain.set(value: response.access_token, for: .googleAccessToken(email: email))
        if let refresh = response.refresh_token, !refresh.isEmpty {
            keychain.set(value: refresh, for: .googleRefreshToken(email: email))
        }
        let expiry = Date().timeIntervalSince1970 + Double(response.expires_in ?? 3600)
        keychain.set(value: String(expiry), for: .googleTokenExpiry(email: email))
    }

    /// Returns a non-expired access token, refreshing with the stored refresh
    /// token when the current one is within a minute of expiring.
    static func validAccessToken(email: String, keychain: KeychainStore = .shared,
                                 session: URLSession = .shared) async throws -> String {
        let now = Date().timeIntervalSince1970
        if let access = keychain.value(for: .googleAccessToken(email: email)), !access.isEmpty,
           let expiryString = keychain.value(for: .googleTokenExpiry(email: email)),
           let expiry = Double(expiryString), now < expiry - 60 {
            return access
        }
        return try await refresh(email: email, keychain: keychain, session: session)
    }

    static func refresh(email: String, keychain: KeychainStore = .shared,
                        session: URLSession = .shared) async throws -> String {
        guard AuthSecrets.isGoogleConfigured else { throw OAuthError.notConfigured(provider: "Google") }
        guard let refreshToken = keychain.value(for: .googleRefreshToken(email: email)), !refreshToken.isEmpty else {
            throw OAuthError.tokenExchangeFailed("Google sign-in has expired. Reconnect the account.")
        }
        let body = OAuth.formURLEncoded([
            "client_id": AuthSecrets.googleClientId,
            "client_secret": AuthSecrets.googleClientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ])
        let response = try await post(body: body, context: "Google token refresh", session: session)
        store(email: email, response: response, keychain: keychain)
        return response.access_token
    }

    private static func post(body: Data, context: String, session: URLSession) async throws -> GoogleTokenResponse {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try validate(response, data, context: context)
        return try parseTokenResponse(data)
    }

    private static func validate(_ response: URLResponse, _ data: Data, context: String) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? "HTTP \(http.statusCode)"
        throw OAuthError.tokenExchangeFailed("\(context) failed (HTTP \(http.statusCode)): \(snippet)")
    }
}

/// Interactive Google connect flow.
@MainActor
final class GoogleAuthService {
    static let shared = GoogleAuthService()

    static let loopbackPort: UInt16 = 53118
    static var redirectURI: String { "http://localhost:\(loopbackPort)/oauth/google" }

    private static let authorizeBase = "https://accounts.google.com/o/oauth2/v2/auth"
    static let scopes = "openid email https://www.googleapis.com/auth/documents https://www.googleapis.com/auth/drive.file https://www.googleapis.com/auth/drive.metadata.readonly"

    static func authorizeURL(clientId: String, state: String, challenge: String) -> URL {
        var components = URLComponents(string: authorizeBase)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        return components.url!
    }

    @discardableResult
    func connect() async throws -> GoogleAccount {
        guard AuthSecrets.isGoogleConfigured else { throw OAuthError.notConfigured(provider: "Google") }

        let state = OAuth.randomState()
        let verifier = OAuth.pkceVerifier()
        let challenge = OAuth.pkceChallenge(for: verifier)
        let authorizeURL = Self.authorizeURL(clientId: AuthSecrets.googleClientId, state: state, challenge: challenge)

        let server = LoopbackOAuthServer()
        async let callback = server.waitForCallback(port: Self.loopbackPort)
        NSWorkspace.shared.open(authorizeURL)
        let items = try await callback

        guard items["state"] == state else { throw OAuthError.stateMismatch }
        if let error = items["error"] {
            throw OAuthError.tokenExchangeFailed("Google declined the connection: \(error)")
        }
        guard let code = items["code"] else { throw OAuthError.missingAuthorizationCode }

        let token = try await GoogleTokens.exchangeCode(code: code, verifier: verifier, redirectURI: Self.redirectURI)
        let email = try await GoogleTokens.fetchEmail(accessToken: token.access_token)
        GoogleTokens.store(email: email, response: token)
        return GoogleAccount(id: email, displayName: email, connectedAt: Date())
    }
}
