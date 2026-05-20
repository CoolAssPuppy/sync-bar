//
//  GoogleDocsDestinationClient.swift
//  Sync Bar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// Writes a transcribed page into Google Docs via the Docs + Drive APIs.
/// Uses the OAuth account's refresh token to mint a fresh access token before
/// each write. Without a connected account it falls back to a mock so the UI
/// flows still feel real.
struct GoogleDocsDestinationClient: DestinationClient {
    let kind: DestinationKind = .googleDocs

    func write(payload: DestinationPayload, configuration: DestinationConfiguration, existingExternalId: String?) async throws -> DestinationWriteResult {
        guard case .googleDocs(let config) = configuration else {
            throw DestinationError.wrongConfiguration(expected: .googleDocs)
        }
        let hasAccount = !(KeychainStore.shared.value(for: .googleRefreshToken(email: config.accountEmail)) ?? "").isEmpty
        guard hasAccount else {
            return try await writeWithMock(config: config, payload: payload, existingId: existingExternalId)
        }
        let token = try await GoogleTokens.validAccessToken(email: config.accountEmail)
        // Update in place: rewrite the doc we made before so an edited note
        // doesn't create a second document.
        if let docId = existingExternalId, !docId.isEmpty {
            return try await rewriteDoc(token: token, docId: docId, payload: payload)
        }
        switch config.appendMode {
        case .onePerPage:
            return try await createDocPerPage(token: token, config: config, payload: payload)
        case .appendToSingleDoc:
            return try await appendToSingleDoc(token: token, config: config, payload: payload)
        }
    }

    // MARK: Update in place

    private func rewriteDoc(token: String, docId: String, payload: DestinationPayload) async throws -> DestinationWriteResult {
        let endIndex = try await documentEndIndex(token: token, docId: docId)
        var requests: [[String: Any]] = []
        // The body always ends in a newline at endIndex-1 that can't be deleted;
        // clear everything before it, then insert the fresh transcript at the top.
        if endIndex > 2 {
            requests.append(["deleteContentRange": ["range": ["startIndex": 1, "endIndex": endIndex - 1]]])
        }
        requests.append(["insertText": ["text": bodyText(payload), "location": ["index": 1]]])

        var request = URLRequest(url: URL(string: "https://docs.googleapis.com/v1/documents/\(docId):batchUpdate")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["requests": requests])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)

        try await renameDocument(token: token, docId: docId, name: payload.title)
        return result(for: docId)
    }

    private func documentEndIndex(token: String, docId: String) async throws -> Int {
        var components = URLComponents(string: "https://docs.googleapis.com/v1/documents/\(docId)")!
        components.queryItems = [URLQueryItem(name: "fields", value: "body(content(endIndex))")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
        struct Doc: Decodable {
            struct Body: Decodable { struct Element: Decodable { let endIndex: Int? }; let content: [Element]? }
            let body: Body?
        }
        let parsed = try JSONDecoder().decode(Doc.self, from: data)
        return parsed.body?.content?.compactMap(\.endIndex).max() ?? 1
    }

    private func renameDocument(token: String, docId: String, name: String) async throws {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(docId)")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
    }

    // MARK: One doc per page

    private func createDocPerPage(token: String, config: GoogleDocsDestinationConfig, payload: DestinationPayload) async throws -> DestinationWriteResult {
        let docId = try await createDocument(token: token, name: payload.title, folderId: config.folderId)
        try await insertText(token: token, docId: docId, text: bodyText(payload), atEnd: false)
        return result(for: docId)
    }

    // MARK: Append to a single doc

    private func appendToSingleDoc(token: String, config: GoogleDocsDestinationConfig, payload: DestinationPayload) async throws -> DestinationWriteResult {
        let docName = "\(payload.ruleNotebookName) (Sync Bar)"
        let docId: String
        if let existing = try await findDocument(token: token, name: docName) {
            docId = existing
        } else {
            docId = try await createDocument(token: token, name: docName, folderId: config.folderId)
        }
        let section = "\n\n\(payload.title)\n\(bodyText(payload))"
        try await insertText(token: token, docId: docId, text: section, atEnd: true)
        return result(for: docId)
    }

    // MARK: Drive + Docs primitives

    private func createDocument(token: String, name: String, folderId: String?) async throws -> String {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["name": name, "mimeType": "application/vnd.google-apps.document"]
        if let folderId, !folderId.isEmpty { body["parents"] = [folderId] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
        struct DriveFile: Decodable { let id: String }
        return try JSONDecoder().decode(DriveFile.self, from: data).id
    }

    private func findDocument(token: String, name: String) async throws -> String? {
        let escapedName = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let query = "name = '\(escapedName)' and mimeType = 'application/vnd.google-apps.document' and trashed = false"
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id)"),
            URLQueryItem(name: "pageSize", value: "1")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
        struct FileList: Decodable { struct File: Decodable { let id: String }; let files: [File] }
        return (try? JSONDecoder().decode(FileList.self, from: data))?.files.first?.id
    }

    private func insertText(token: String, docId: String, text: String, atEnd: Bool) async throws {
        let location: [String: Any] = atEnd ? ["endOfSegmentLocation": [:]] : ["location": ["index": 1]]
        var insert: [String: Any] = ["text": text]
        for (key, value) in location { insert[key] = value }

        var request = URLRequest(url: URL(string: "https://docs.googleapis.com/v1/documents/\(docId):batchUpdate")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["requests": [["insertText": insert]]])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
    }

    private func bodyText(_ payload: DestinationPayload) -> String {
        payload.body + (payload.mermaidSource.map { "\n\n[Mermaid diagram]\n\($0)" } ?? "")
    }

    private func result(for docId: String) -> DestinationWriteResult {
        DestinationWriteResult(
            externalId: docId,
            externalURL: URL(string: "https://docs.google.com/document/d/\(docId)/edit"),
            notes: nil
        )
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403:  throw DestinationError.apiFailed(status: http.statusCode, snippet: "Google rejected the request. Reconnect the account.")
        case 429:       throw DestinationError.rateLimited
        default:
            let snippet = String(data: data, encoding: .utf8)?.prefix(200).description ?? "HTTP \(http.statusCode)"
            throw DestinationError.apiFailed(status: http.statusCode, snippet: snippet)
        }
    }

    // MARK: Mock fallback

    private func writeWithMock(config: GoogleDocsDestinationConfig, payload: DestinationPayload, existingId: String?) async throws -> DestinationWriteResult {
        try await Task.sleep(nanoseconds: 200_000_000)
        let id = existingId ?? String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))
        return DestinationWriteResult(
            externalId: id,
            externalURL: URL(string: "https://docs.google.com/document/d/\(id)/edit"),
            notes: "Mock Google Docs write (no account connected)."
        )
    }
}
