//
//  OAuthWebSession.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import AuthenticationServices
import AppKit
import CryptoKit

/// Errors surfaced by the OAuth connect flows.
enum OAuthError: LocalizedError, Equatable {
    case notConfigured(provider: String)
    case userCancelled
    case cannotStartSession
    case stateMismatch
    case missingAuthorizationCode
    case tokenExchangeFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let provider):
            return "\(provider) isn't configured yet. Add its OAuth client credentials (see the README) and rebuild."
        case .userCancelled:
            return "Sign-in was cancelled."
        case .cannotStartSession:
            return "Couldn't open the sign-in window."
        case .stateMismatch:
            return "Sign-in failed a security check (state mismatch). Please try again."
        case .missingAuthorizationCode:
            return "The provider didn't return an authorization code."
        case .tokenExchangeFailed(let message):
            return message
        case .invalidResponse(let message):
            return message
        }
    }
}

/// Thin async wrapper around `ASWebAuthenticationSession`. Opens the provider's
/// authorize URL in a secure, app-bound web session and resolves with the
/// redirect (`syncnerds://oauth/...`) URL once the provider sends the user back.
/// The session intercepts the callback scheme itself, so no AppDelegate URL
/// handler is required.
@MainActor
final class OAuthWebSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func start(authorizeURL: URL, callbackURLScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callbackURLScheme: callbackURLScheme
            ) { callbackURL, error in
                if let error {
                    if let asError = error as? ASWebAuthenticationSessionError, asError.code == .canceledLogin {
                        continuation.resume(throwing: OAuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: OAuthError.userCancelled)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: OAuthError.cannotStartSession)
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible })
            ?? NSApp.windows.first
            ?? NSWindow()
    }
}

/// Stateless OAuth helpers shared by the provider auth services.
enum OAuth {
    /// Callback scheme registered in Info.plist and used by every flow.
    static let callbackScheme = "syncnerds"

    /// The redirect URI a provider must be configured with, e.g.
    /// `syncnerds://oauth/linear`.
    static func redirectURI(provider: String) -> String {
        "\(callbackScheme)://oauth/\(provider)"
    }

    /// A random, URL-safe `state` token for CSRF protection.
    static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    /// A PKCE code verifier: 32 random bytes, base64url-encoded (RFC 7636).
    static func pkceVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    /// The S256 PKCE challenge for a verifier: base64url(SHA256(verifier)).
    static func pkceChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    /// Encodes fields as an `application/x-www-form-urlencoded` body, percent
    /// encoding everything outside the RFC 3986 unreserved set so values that
    /// contain `+`, `/`, or `&` survive the round trip.
    static func formURLEncoded(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = fields.map { key, value -> String in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    /// Extracts a query item from a redirect callback URL.
    static func queryValue(_ name: String, from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
