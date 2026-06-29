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

    // MARK: Polar (paid Sync class)

    /// Polar organization id — required to validate/activate license keys. Public
    /// (it's the org UUID), so it ships in the app like the OAuth client ids.
    static var polarOrganizationId: String { value(infoKey: "PolarOrgID", env: "POLAR_ORG_ID") }

    /// Hosted checkout for the paid subscription. The paywall's Subscribe button
    /// opens it; nil until the Polar product exists, which disables the button.
    static var polarCheckoutURL: URL? { url(infoKey: "PolarCheckoutURL", env: "POLAR_CHECKOUT_URL") }

    /// Polar customer portal — where a subscriber manages or cancels. Linked from
    /// Settings; nil until configured.
    static var polarPortalURL: URL? { url(infoKey: "PolarPortalURL", env: "POLAR_PORTAL_URL") }

    /// The server-side relay that holds the Polar access token and ingests usage
    /// events. The app posts read counts here; nil until deployed, in which case
    /// `UsageReporter` no-ops (entitlement still works without it).
    static var polarUsageRelayURL: URL? { url(infoKey: "PolarUsageRelayURL", env: "POLAR_USAGE_RELAY_URL") }

    /// License keys can be validated without a server, so a Polar org id alone is
    /// enough to gate the paid source and show the paste field.
    static var isPolarConfigured: Bool { !polarOrganizationId.isEmpty }

    /// Privacy policy linked from the consent sheet and Settings. Placeholder
    /// until a real policy is hosted (the paid source is the first to collect
    /// personal data, so this must be live before shipping).
    static let privacyPolicyURL = URL(staticString: "https://www.strategicnerds.com/privacy")

    private static func url(infoKey: String, env: String) -> URL? {
        let raw = value(infoKey: infoKey, env: env)
        return raw.isEmpty ? nil : URL(string: raw)
    }

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
