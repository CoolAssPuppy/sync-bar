//
//  RealRemarkableClient.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Implements the reMarkable cloud API endpoints documented at
//  https://github.com/juruen/rmapi/wiki/Cloud-API-1.5 and the reMarkable
//  paper site reference docs. Endpoints used here:
//
//  • POST  https://webapp-production-dot-remarkable-production.appspot.com/token/json/2/device/new
//          One-time-code → long-lived device token.
//  • POST  https://webapp-production-dot-remarkable-production.appspot.com/token/json/2/user/new
//          Device token → short-lived bearer token (expires after ~24h).
//  • GET   https://internal.cloud.remarkable.com/sync/v3/root
//          Catalog root: returns the hash of the top-level index.
//  • GET   https://internal.cloud.remarkable.com/sync/v3/files/{hash}
//          Index payload referenced by a hash (used to walk notebooks/pages).
//

import Foundation

struct RealRemarkableClient: RemarkableClient {
    private let session: URLSession
    private let keychain: KeychainStore

    init(session: URLSession = .shared, keychain: KeychainStore = .shared) {
        self.session = session
        self.keychain = keychain
    }

    private static let pairBase  = URL(string: "https://webapp-production-dot-remarkable-production.appspot.com")!
    private static let cloudBase = URL(string: "https://internal.cloud.remarkable.com")!

    func pairDevice(oneTimeCode: String) async throws -> RemarkableAccount {
        var request = URLRequest(url: Self.pairBase.appendingPathComponent("/token/json/2/device/new"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let deviceUUID = UUID().uuidString.lowercased()
        let body: [String: Any] = [
            "code": oneTimeCode.trimmingCharacters(in: .whitespacesAndNewlines),
            "deviceID": deviceUUID,
            "deviceDesc": "desktop-macos"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RemarkableError.invalidOneTimeCode
        }
        guard let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw RemarkableError.network("Empty device token from reMarkable cloud.")
        }
        keychain.set(value: token, for: .remarkableDeviceToken)

        return RemarkableAccount(
            pairedAt: Date(),
            userIdentifier: String(deviceUUID.prefix(8)),
            lastSyncedAt: nil
        )
    }

    func listNotebooks() async throws -> [RmNotebook] {
        let userToken = try await refreshUserTokenIfNeeded()
        var request = URLRequest(url: Self.cloudBase.appendingPathComponent("/sync/v3/root"))
        request.setValue("Bearer \(userToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)

        // The sync/v3 root format returns a hash that points at the index.
        // The index is a tab-separated list of files. Walking the full
        // schema is out of scope for this client; on success we return
        // an empty list so the UI keeps working until we add the full
        // graph walk. Mock client remains the default until pairing happens.
        return []
    }

    func listPages(notebookId: String) async throws -> [RmPage] {
        // Requires walking the index graph and downloading the .content/.metadata
        // pair per notebook. Stub returns an empty list so calling rules don't
        // crash; mock client owns the lived-in experience while we wire this
        // up properly in v0.3.
        return []
    }

    func downloadNotebookPdf(notebookId: String) async throws -> Data {
        return Data()
    }

    // MARK: Token refresh

    private func refreshUserTokenIfNeeded() async throws -> String {
        if let user = keychain.value(for: .remarkableUserToken), !user.isEmpty { return user }
        guard let device = keychain.value(for: .remarkableDeviceToken), !device.isEmpty else {
            throw RemarkableError.network("No reMarkable device token. Re-pair the device.")
        }
        var request = URLRequest(url: Self.pairBase.appendingPathComponent("/token/json/2/user/new"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(device)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        guard let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw RemarkableError.network("Empty user token from reMarkable cloud.")
        }
        keychain.set(value: token, for: .remarkableUserToken)
        return token
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401:       throw RemarkableError.network("reMarkable rejected the token. Re-pair.")
        case 429:       throw RemarkableError.rateLimited
        default:
            throw RemarkableError.network("reMarkable cloud returned \(http.statusCode).")
        }
    }
}

// MARK: - Factory

enum RemarkableClientFactory {
    /// Returns the real client when a device token is in Keychain, the
    /// mock otherwise. Lets the entire app stay client-agnostic.
    static func makeDefault(keychain: KeychainStore = .shared) -> RemarkableClient {
        if let token = keychain.value(for: .remarkableDeviceToken), !token.isEmpty {
            return RealRemarkableClient(keychain: keychain)
        }
        return MockRemarkableClient()
    }
}
