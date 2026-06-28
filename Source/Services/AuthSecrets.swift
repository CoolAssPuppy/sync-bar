//
//  AuthSecrets.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// OAuth client credentials, resolved at runtime.
///
/// Values flow from the Doppler `sync-bar` project into `Secrets.xcconfig`
/// (gitignored), which the build bakes into the app's Info.plist. Each lookup
/// also honors a process-environment override so `doppler run -- make build`
/// works in development. Missing credentials resolve to an empty string, and
/// the matching `*Configured` flag reports the provider as unavailable so the
/// UI can disable its connect button instead of starting a doomed flow.
enum AuthSecrets {
    static var notionClientId: String { value(infoKey: "NotionClientID", env: "NOTION_CLIENT_ID") }
    static var notionClientSecret: String { value(infoKey: "NotionClientSecret", env: "NOTION_CLIENT_SECRET") }
    static var linearClientId: String { value(infoKey: "LinearClientID", env: "LINEAR_CLIENT_ID") }
    static var linearClientSecret: String { value(infoKey: "LinearClientSecret", env: "LINEAR_CLIENT_SECRET") }
    static var googleClientId: String { value(infoKey: "GoogleClientID", env: "GOOGLE_CLIENT_ID") }
    static var googleClientSecret: String { value(infoKey: "GoogleClientSecret", env: "GOOGLE_CLIENT_SECRET") }
    static var xClientId: String { value(infoKey: "XClientID", env: "X_CLIENT_ID") }
    static var xClientSecret: String { value(infoKey: "XClientSecret", env: "X_CLIENT_SECRET") }

    static var isNotionConfigured: Bool { !notionClientId.isEmpty && !notionClientSecret.isEmpty }
    static var isLinearConfigured: Bool { !linearClientId.isEmpty && !linearClientSecret.isEmpty }
    static var isGoogleConfigured: Bool { !googleClientId.isEmpty && !googleClientSecret.isEmpty }
    /// X supports both confidential (client id + secret) and public (PKCE-only)
    /// OAuth 2.0 clients, so a client id alone is enough to start the flow —
    /// "bring your own Twitter key" works with just the id.
    static var isXConfigured: Bool { !xClientId.isEmpty }

    private static func value(infoKey: String, env: String) -> String {
        if let fromEnv = ProcessInfo.processInfo.environment[env], !fromEnv.isEmpty {
            return fromEnv
        }
        guard let raw = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String else { return "" }
        // An unresolved build variable would arrive as the literal "$(NAME)".
        if raw.isEmpty || raw.hasPrefix("$(") { return "" }
        return raw
    }
}
