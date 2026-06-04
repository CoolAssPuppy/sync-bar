//
//  RemarkableUploaderNetworkTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Drives RemarkableUploader against an in-memory fake reMarkable cloud (via a
//  stub URLProtocol) to pin the write sequence end-to-end: the blob PUTs with
//  extensioned rm-filename and x-goog-hash headers, the v4 root read, the v3
//  root commit, and the HTTP 412 generation-conflict re-mirror/retry.
//

import XCTest
@testable import SyncBar

final class RemarkableUploaderNetworkTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func writeTempPDF(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("%PDF-1.4 fake".utf8).write(to: url)
        return url
    }

    func test_upload_puts_components_then_commits_root() async throws {
        let cloud = FakeRemarkableCloud()
        StubURLProtocol.handler = { request, body in cloud.handle(request, body: body) }

        let uploader = RemarkableUploader(session: makeSession(), tokenOverride: "test-token")
        let progress = ProgressRecorder()
        let url = try writeTempPDF(named: "My Book.pdf")

        let result = try await uploader.uploadDocument(fileURL: url, toFolderId: "folder-xyz") { value in
            progress.record(value)
        }

        XCTAssertEqual(result.visibleName, "My Book")
        XCTAssertFalse(result.documentId.isEmpty)
        XCTAssertEqual(progress.last, 1.0, accuracy: 0.0001)

        // Every component blob was PUT with an extensioned rm-filename + x-goog-hash.
        let blobPuts = cloud.requests.filter { $0.method == "PUT" && $0.path.hasPrefix("/sync/v3/files/") }
        let filenames = Set(blobPuts.compactMap { $0.rmFilename })
        XCTAssertTrue(filenames.contains("\(result.documentId).pdf"))
        XCTAssertTrue(filenames.contains("\(result.documentId).metadata"))
        XCTAssertTrue(filenames.contains("\(result.documentId).content"))
        XCTAssertTrue(filenames.contains("\(result.documentId).docSchema"))
        XCTAssertTrue(filenames.contains("root.docSchema"))
        XCTAssertTrue(blobPuts.allSatisfy { ($0.gHash ?? "").hasPrefix("crc32c=") })

        // The document landed in the cloud root under the chosen parent.
        XCTAssertTrue(cloud.rootContainsDoc(result.documentId))
        XCTAssertEqual(cloud.parentOfLastMetadata(), "folder-xyz")

        // Exactly one successful root commit.
        XCTAssertEqual(cloud.requests.filter { $0.method == "PUT" && $0.path == "/sync/v3/root" }.count, 1)
    }

    func test_upload_retries_on_generation_conflict() async throws {
        let cloud = FakeRemarkableCloud()
        cloud.failNextRootCommitOnce = true
        StubURLProtocol.handler = { request, body in cloud.handle(request, body: body) }

        let uploader = RemarkableUploader(session: makeSession(), tokenOverride: "test-token")
        let url = try writeTempPDF(named: "Doc.pdf")

        let result = try await uploader.uploadDocument(fileURL: url, toFolderId: "") { _ in }

        // The 412 forced a re-read of /sync/v4/root and a second root commit.
        XCTAssertEqual(cloud.requests.filter { $0.method == "PUT" && $0.path == "/sync/v3/root" }.count, 2)
        XCTAssertTrue(cloud.rootContainsDoc(result.documentId))
    }

    func test_unsupported_type_throws_before_any_network() async throws {
        StubURLProtocol.handler = { _, _ in (500, Data()) }   // any network call would 500
        let uploader = RemarkableUploader(session: makeSession(), tokenOverride: "test-token")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("note.txt")
        try Data("hi".utf8).write(to: url)

        do {
            _ = try await uploader.uploadDocument(fileURL: url, toFolderId: "") { _ in }
            XCTFail("expected unsupportedFileType")
        } catch RemarkableError.unsupportedFileType {
            // expected
        }
    }
}

// MARK: - Progress recorder (thread-safe)

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func record(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
    var last: Double { lock.lock(); defer { lock.unlock() }; return values.last ?? -1 }
}

// MARK: - Stub URLProtocol

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request, Self.readBody(request))
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - In-memory fake reMarkable cloud

final class FakeRemarkableCloud: @unchecked Sendable {
    struct Recorded { let method: String; let path: String; let rmFilename: String?; let gHash: String? }

    private let lock = NSLock()
    private var blobs: [String: Data] = [:]
    private var rootHash: String
    private var generation = 1
    private var lastMetadataParent: String?
    var failNextRootCommitOnce = false
    private(set) var requests: [Recorded] = []

    init() {
        let empty = Data(RemarkableSyncIndex.serializeRootIndex([]).utf8)
        rootHash = RemarkableUploader.leafHash(empty)
        blobs[rootHash] = empty
    }

    func rootContainsDoc(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let data = blobs[rootHash],
              let docs = try? RemarkableSyncIndex.parseRootIndexV4(String(decoding: data, as: UTF8.self)) else {
            return false
        }
        return docs.contains { $0.id == id }
    }

    func parentOfLastMetadata() -> String? {
        lock.lock(); defer { lock.unlock() }
        return lastMetadataParent
    }

    func handle(_ request: URLRequest, body: Data) -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let rmFilename = request.value(forHTTPHeaderField: "rm-filename")
        requests.append(Recorded(method: method, path: path, rmFilename: rmFilename,
                                 gHash: request.value(forHTTPHeaderField: "x-goog-hash")))

        if path == "/sync/v4/root", method == "GET" {
            return (200, Data("{\"hash\":\"\(rootHash)\",\"generation\":\(generation),\"schemaVersion\":3}".utf8))
        }

        if path == "/sync/v3/root", method == "PUT" {
            struct Body: Decodable { let hash: String; let generation: Int }
            guard let parsed = try? JSONDecoder().decode(Body.self, from: body) else { return (400, Data()) }
            if failNextRootCommitOnce {
                failNextRootCommitOnce = false
                generation += 1   // simulate a concurrent writer so the retry can win
                return (412, Data())
            }
            guard parsed.generation == generation else { return (412, Data()) }
            rootHash = parsed.hash
            generation += 1
            return (200, Data("{\"hash\":\"\(rootHash)\",\"generation\":\(generation),\"schemaVersion\":3}".utf8))
        }

        if path.hasPrefix("/sync/v3/files/") {
            let hash = String(path.dropFirst("/sync/v3/files/".count))
            if method == "PUT" {
                // Mirror the real server: every blob is content-addressed by the
                // SHA-256 of its own bytes; a mismatch is 400 "invalid hash".
                guard RemarkableUploader.leafHash(body) == hash else {
                    return (400, Data("{\"message\":\"invalid hash\"}".utf8))
                }
                blobs[hash] = body
                if rmFilename?.hasSuffix(".metadata") == true,
                   let meta = try? RemarkableSyncIndex.parseMetadata(body) {
                    lastMetadataParent = meta.parent
                }
                return (200, Data())
            }
            return blobs[hash].map { (200, $0) } ?? (404, Data())
        }

        return (404, Data())
    }
}
