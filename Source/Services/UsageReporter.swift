//
//  UsageReporter.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Reports paid-class usage (tweets read) to the Polar event-ingestion relay so
//  it can be metered and billed. Polar's ingestion needs an Organization Access
//  Token that must never ship in the app, so the app posts to a small server-side
//  relay that holds the token, validates the license key, resolves the customer,
//  and ingests the event. The app sends the license key (not a client-trusted
//  customer id) so attribution stays authoritative server-side.
//
//  Best-effort by design: a failure here never affects the sync. When no relay is
//  configured (or there's no license key), it no-ops, so entitlement still works
//  with no server — only metered billing needs the relay deployed.
//

import Foundation

struct UsageReporter: Sendable {
    private let relayURL: URL?
    private let session: URLSession

    init(relayURL: URL? = AuthSecrets.polarUsageRelayURL, session: URLSession = .shared) {
        self.relayURL = relayURL
        self.session = session
    }

    /// Posts a read count to the relay. No-ops when there's nothing to bill, no
    /// relay deployed, or no license key. Never throws — billing must not break a sync.
    func report(reads: Int, licenseKey: String?, properties: [String: String] = [:]) async {
        guard reads > 0,
              let relayURL,
              let licenseKey, !licenseKey.isEmpty else { return }

        var body: [String: Any] = properties
        body["license_key"] = licenseKey
        body["reads"] = reads

        var request = URLRequest(url: relayURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await session.data(for: request)
    }
}
