//
//  RealRemarkableClient.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Talks to the reMarkable cloud. Pairing and token refresh use the documented
//  1.5 token endpoints; listing walks the sync content-addressed blob store
//  (root index -> per-document index -> .metadata / .content / per-page .rm),
//  and page images are rasterized from the page's v6 .rm blob.
//
//  The blob-store endpoints and host are reverse-engineered and should be
//  confirmed against a live device; the index/metadata parsing and the v6
//  reader they feed are unit-tested independently.
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

    // MARK: Pairing

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

    // MARK: Listing

    func listNotebooks() async throws -> [RmNotebook] {
        let documents = try await rootIndexEntries()
        var notebooks: [RmNotebook] = []
        for document in documents {
            guard let components = try? await documentComponents(documentHash: document.hash),
                  let metadataEntry = RemarkableSyncIndex.metadataEntry(in: components),
                  let metadataData = try? await blob(hash: metadataEntry.hash),
                  let metadata = try? RemarkableSyncIndex.parseMetadata(metadataData),
                  metadata.isNotebook else { continue }
            notebooks.append(RmNotebook(
                id: document.identifier,
                name: metadata.visibleName,
                parentFolder: nil,
                lastModified: metadata.lastModified,
                pageCount: RemarkableSyncIndex.pageBlobHashes(in: components).count
            ))
        }
        return notebooks
    }

    func listPages(notebookId: String) async throws -> [RmPage] {
        let documents = try await rootIndexEntries()
        guard let document = documents.first(where: { $0.identifier == notebookId }) else { return [] }
        let components = try await documentComponents(documentHash: document.hash)

        let lastModified: Date
        if let metadataEntry = RemarkableSyncIndex.metadataEntry(in: components),
           let metadataData = try? await blob(hash: metadataEntry.hash),
           let metadata = try? RemarkableSyncIndex.parseMetadata(metadataData) {
            lastModified = metadata.lastModified
        } else {
            lastModified = Date()
        }

        let pageHashes = RemarkableSyncIndex.pageBlobHashes(in: components)
        var order: [String] = []
        if let contentEntry = RemarkableSyncIndex.contentEntry(in: components),
           let contentData = try? await blob(hash: contentEntry.hash),
           let parsed = try? RemarkableSyncIndex.parseContentPageOrder(contentData) {
            order = parsed
        }
        if order.isEmpty { order = Array(pageHashes.keys) }

        return order.enumerated().compactMap { index, pageUuid in
            guard let blobHash = pageHashes[pageUuid] else { return nil }
            return RmPage(
                notebookId: notebookId,
                pageId: pageUuid,
                positionInNotebook: index,
                createdAt: lastModified,
                modifiedAt: lastModified,
                hasTypedText: false,
                versionHash: blobHash
            )
        }
    }

    func pageImage(for page: RmPage) async throws -> Data? {
        let data = try await blob(hash: page.versionHash)
        guard let drawing = try? RemarkableLinesV6.parse(data), !drawing.isEmpty else { return nil }
        return RemarkableRenderer.pngData(for: drawing)
    }

    // MARK: Blob store

    private func rootIndexEntries() async throws -> [RemarkableIndexEntry] {
        let rootData = try await authedData(path: "/sync/v3/root")
        let rootHash = Self.parseRootHash(rootData)
        let indexData = try await blob(hash: rootHash)
        return try RemarkableSyncIndex.parseIndex(String(decoding: indexData, as: UTF8.self))
    }

    private func documentComponents(documentHash: String) async throws -> [RemarkableIndexEntry] {
        let data = try await blob(hash: documentHash)
        return try RemarkableSyncIndex.parseIndex(String(decoding: data, as: UTF8.self))
    }

    private func blob(hash: String) async throws -> Data {
        try await authedData(path: "/sync/v3/files/\(hash)")
    }

    static func parseRootHash(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hash = object["hash"] as? String {
            return hash
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Auth

    private func authedData(path: String) async throws -> Data {
        let token = try await refreshUserTokenIfNeeded()
        var request = URLRequest(url: Self.cloudBase.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return data
    }

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
        default:        throw RemarkableError.network("reMarkable cloud returned \(http.statusCode).")
        }
    }
}
