//
//  RemarkableUploader.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The reMarkable cloud WRITE path ("sync 1.5 / v3"), kept separate from the
//  read-only RealRemarkableClient so the risky upload logic is isolated.
//
//  Protocol (cross-verified June 2026 against ddvk/rmapi, ddvk/rmfakecloud, and
//  the independent erikbrinkman/rmapi-js):
//    - Each blob: PUT /sync/v3/files/<sha256hex>, headers Authorization,
//      rm-filename (WITH extension — a 2026 hard requirement), x-goog-hash
//      crc32c, content-type (octet-stream; text/plain for the root index).
//    - Root: GET /sync/v4/root -> {hash,generation}; PUT /sync/v3/root body
//      {broadcast,hash,generation}; HTTP 412 = generation conflict -> re-mirror
//      and retry. The root index MUST be schema v4 (another 2026 requirement).
//    - Hashing: leaf = sha256(bytes); doc = sha256(concat of raw-decoded child
//      digests sorted by filename); root = sha256(serialized v4 index text).
//
//  These endpoints are reverse-engineered and unvalidated against a live device
//  for writes. The uploader only ever APPENDS a document line to the root — it
//  never rewrites or deletes existing lines — and aborts (never forces) on a
//  generation conflict.
//

import Foundation
import CryptoKit
import PDFKit

struct RemarkableUploader: Sendable {
    /// Raised internally when the root generation advanced under us (HTTP 412),
    /// driving the re-mirror/retry loop.
    private struct GenerationConflict: Error {}

    private let session: URLSession
    private let keychain: KeychainStore
    /// Test seam: when set, `userToken()` returns this instead of reading the
    /// keychain / minting from the device token. Always nil in production.
    private let tokenOverride: String?

    init(session: URLSession = .shared, keychain: KeychainStore = .shared, tokenOverride: String? = nil) {
        self.session = session
        self.keychain = keychain
        self.tokenOverride = tokenOverride
    }

    private static let pairBase  = URL(staticString: "https://webapp.cloud.remarkable.com")
    private static let cloudBase = URL(staticString: "https://internal.cloud.remarkable.com")
    private static let maxGenerationRetries = 10

    // Per-file progress weights (sum to 1.0): the source blob dominates bytes.
    private static let sourceWeight = 0.70
    private static let metadataWeight = 0.05
    private static let contentWeight = 0.05
    private static let docSchemaWeight = 0.05
    // Remaining 0.15 covers the root commit.

    // MARK: - Upload

    func uploadDocument(fileURL: URL,
                        toFolderId folderId: String,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> RmUploadResult {
        let ext = fileURL.pathExtension.lowercased()
        let fileType: String
        switch ext {
        case "pdf":  fileType = "pdf"
        case "epub": fileType = "epub"
        default:     throw RemarkableError.unsupportedFileType(fileURL.lastPathComponent)
        }

        // Read the file. Non-sandboxed today, but scope the access for robustness.
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        let fileData = try Data(contentsOf: fileURL)

        let docId = UUID().uuidString.lowercased()
        let visibleName = fileURL.deletingPathExtension().lastPathComponent
        let pageCount = (fileType == "pdf") ? (PDFDocument(data: fileData)?.pageCount ?? 0) : 0

        let metadataData = try RemarkableSyncIndex.serializeMetadata(
            visibleName: visibleName, parent: folderId, type: "DocumentType", lastModified: Date())
        let contentData = try RemarkableSyncIndex.serializeContent(fileType: fileType, pageCount: pageCount)

        let components: [(name: String, data: Data, weight: Double)] = [
            ("\(docId).\(fileType)", fileData, Self.sourceWeight),
            ("\(docId).metadata", metadataData, Self.metadataWeight),
            ("\(docId).content", contentData, Self.contentWeight)
        ]

        progress(0)
        var cumulative = 0.0
        var entries: [RemarkableIndexEntry] = []
        for component in components {
            let hash = Self.leafHash(component.data)
            try await putBlob(data: component.data, sha256hex: hash,
                              rmFilename: component.name, contentType: "application/octet-stream")
            entries.append(RemarkableIndexEntry(hash: hash, type: "0",
                                                identifier: component.name, subfiles: 0,
                                                size: component.data.count))
            cumulative += component.weight
            progress(cumulative)
        }

        // The per-document index blob. Like every blob it is content-addressed
        // by the SHA-256 of its own bytes (the server validates this, returning
        // 400 "invalid hash" otherwise), and the root index references the
        // document by that same hash so reads resolve back to this blob.
        let docIndexData = Data(RemarkableSyncIndex.serializeDocumentIndex(documentId: docId, entries: entries).utf8)
        let docBlobHash = Self.leafHash(docIndexData)
        try await putBlob(data: docIndexData, sha256hex: docBlobHash,
                          rmFilename: "\(docId).docSchema", contentType: "application/octet-stream")
        cumulative += Self.docSchemaWeight
        progress(cumulative)

        let docSize = entries.reduce(0) { $0 + $1.size }
        let newDoc = RootDocLine(hash: docBlobHash, id: docId, numFiles: entries.count, size: docSize)
        try await commitIntoRoot(newDoc: newDoc)
        progress(1.0)

        // Post-commit verification: re-read the root and confirm the doc landed.
        guard try await rootContains(docId: docId) else {
            throw RemarkableError.network("Upload committed but the document didn't appear in the cloud root.")
        }
        Log.remarkable.info("uploaded \(docId, privacy: .public) into parent \"\(folderId, privacy: .public)\"")
        return RmUploadResult(documentId: docId, visibleName: visibleName)
    }

    // MARK: - Root commit (generation handshake)

    private func commitIntoRoot(newDoc: RootDocLine) async throws {
        for attempt in 0..<Self.maxGenerationRetries {
            let (rootHash, generation) = try await readRootV4()
            let rootIndexData = try await getBlob(hash: rootHash, rmFilename: "root.docSchema")
            var docs = try RemarkableSyncIndex.parseRootIndexV4(String(decoding: rootIndexData, as: UTF8.self))
            docs.removeAll { $0.id == newDoc.id }   // idempotent on retry / re-upload
            docs.append(newDoc)

            let newRootData = Data(RemarkableSyncIndex.serializeRootIndex(docs).utf8)
            let newRootHash = Self.leafHash(newRootData)
            try await putBlob(data: newRootData, sha256hex: newRootHash,
                              rmFilename: "root.docSchema", contentType: "text/plain; charset=UTF-8")
            do {
                try await commitRoot(newHash: newRootHash, expectedGeneration: generation)
                return
            } catch is GenerationConflict {
                Log.remarkable.info("root generation conflict (attempt \(attempt + 1, privacy: .public)); re-mirroring")
                continue
            }
        }
        throw RemarkableError.network("reMarkable cloud is busy (too many concurrent changes). Try again.")
    }

    private func readRootV4() async throws -> (hash: String, generation: Int) {
        struct Root: Decodable { let hash: String; let generation: Int }
        let data = try await authed(method: "GET", path: "/sync/v4/root",
                                    rmFilename: nil, body: nil, contentType: nil)
        let root = try JSONDecoder().decode(Root.self, from: data)
        return (root.hash, root.generation)
    }

    private func commitRoot(newHash: String, expectedGeneration: Int) async throws {
        struct Body: Encodable { let broadcast: Bool; let hash: String; let generation: Int }
        let body = try JSONEncoder().encode(Body(broadcast: true, hash: newHash, generation: expectedGeneration))
        _ = try await authed(method: "PUT", path: "/sync/v3/root", rmFilename: "roothash",
                             body: body, contentType: "application/json", treat412AsConflict: true)
    }

    private func rootContains(docId: String) async throws -> Bool {
        let (rootHash, _) = try await readRootV4()
        let data = try await getBlob(hash: rootHash, rmFilename: "root.docSchema")
        let docs = try RemarkableSyncIndex.parseRootIndexV4(String(decoding: data, as: UTF8.self))
        return docs.contains { $0.id == docId }
    }

    // MARK: - Blob transfer

    private func putBlob(data: Data, sha256hex: String, rmFilename: String, contentType: String) async throws {
        _ = try await authed(method: "PUT", path: "/sync/v3/files/\(sha256hex)",
                             rmFilename: rmFilename, body: data, contentType: contentType,
                             extraHeaders: ["x-goog-hash": CRC32C.googHashHeader(data)])
    }

    private func getBlob(hash: String, rmFilename: String) async throws -> Data {
        try await authed(method: "GET", path: "/sync/v3/files/\(hash)",
                         rmFilename: rmFilename, body: nil, contentType: nil)
    }

    // MARK: - Hashing

    /// Every blob — leaf files, the per-document `.docSchema` index, and the
    /// `root.docSchema` index alike — is content-addressed by the SHA-256 hex of
    /// its own bytes. The server rejects a mismatch with 400 "invalid hash".
    static func leafHash(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).hexEncodedString()
    }

    // MARK: - Authenticated request

    private func authed(method: String, path: String, rmFilename: String?, body: Data?,
                        contentType: String?, treat412AsConflict: Bool = false,
                        extraHeaders: [String: String] = [:]) async throws -> Data {
        var (data, response) = try await send(method: method, path: path, rmFilename: rmFilename,
                                              body: body, contentType: contentType, extraHeaders: extraHeaders)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            // Short-lived user token expired — drop it, mint a fresh one, retry once.
            keychain.delete(key: .remarkableUserToken)
            (data, response) = try await send(method: method, path: path, rmFilename: rmFilename,
                                              body: body, contentType: contentType, extraHeaders: extraHeaders)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if treat412AsConflict && status == 412 { throw GenerationConflict() }
        try Self.validate(status: status, data: data)
        return data
    }

    private func send(method: String, path: String, rmFilename: String?, body: Data?,
                      contentType: String?, extraHeaders: [String: String]) async throws -> (Data, URLResponse) {
        let token = try await userToken()
        var request = URLRequest(url: Self.cloudBase.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("rmapi", forHTTPHeaderField: "user-agent")
        if let rmFilename { request.setValue(rmFilename, forHTTPHeaderField: "rm-filename") }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "content-type") }
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        if let body { request.httpBody = body }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if !(200..<300).contains(status) {
            let snippet = (String(bytes: data, encoding: .utf8) ?? "").prefix(200)
            Log.remarkable.error("\(method, privacy: .public) \(path, privacy: .public) -> HTTP \(status, privacy: .public): \(snippet, privacy: .public)")
        }
        return (data, response)
    }

    /// Mirrors `RealRemarkableClient.refreshUserTokenIfNeeded` so the read struct
    /// stays untouched. The device token is long-lived; the user token is minted
    /// from it and cached until a 401 invalidates it.
    private func userToken() async throws -> String {
        if let tokenOverride { return tokenOverride }
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
        try Self.validate(status: (response as? HTTPURLResponse)?.statusCode ?? -1, data: data)
        guard let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw RemarkableError.network("Empty user token from reMarkable cloud.")
        }
        keychain.set(value: token, for: .remarkableUserToken)
        return token
    }

    private static func validate(status: Int, data: Data) throws {
        switch status {
        case 200..<300: return
        case 401:       throw RemarkableError.network("reMarkable rejected the token. Re-pair.")
        case 429:       throw RemarkableError.rateLimited
        default:
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw RemarkableError.network("reMarkable cloud returned \(status). \(snippet)")
        }
    }
}

// MARK: - Hex helpers

extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let byte = UInt8("\(chars[index])\(chars[index + 1])", radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        self = Data(bytes)
    }
}
