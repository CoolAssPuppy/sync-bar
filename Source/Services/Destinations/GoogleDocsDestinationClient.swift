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
        // The body always ends in a newline at endIndex-1 that can't be deleted;
        // clear everything before it, then insert the fresh content at the top.
        var requests: [[String: Any]] = []
        if endIndex > 2 {
            requests.append(["deleteContentRange": ["range": ["startIndex": 1, "endIndex": endIndex - 1]]])
        }
        requests.append(contentsOf: Self.contentRequests(payload: payload, blocks: payload.blocks, startIndex: 1))
        try await batchUpdate(token: token, docId: docId, requests: requests)
        try await renameDocument(token: token, docId: docId, name: payload.title)
        return result(for: docId)
    }

    private func documentEndIndex(token: String, docId: String) async throws -> Int {
        guard var components = URLComponents(string: "https://docs.googleapis.com/v1/documents/\(docId)") else {
            throw DestinationError.network("Could not build the Google Docs query URL.")
        }
        components.queryItems = [URLQueryItem(name: "fields", value: "body(content(endIndex))")]
        guard let url = components.url else {
            throw DestinationError.network("Could not build the Google Docs query URL.")
        }
        var request = URLRequest(url: url)
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
        guard let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(docId)") else {
            throw DestinationError.network("Could not build the Drive rename URL.")
        }
        var request = URLRequest(url: url)
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
        try await batchUpdate(token: token, docId: docId,
                              requests: Self.contentRequests(payload: payload, blocks: payload.blocks, startIndex: 1))
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
        // Insert before the document's final newline, with the note title as a
        // heading so successive notes stay visually separated.
        let endIndex = try await documentEndIndex(token: token, docId: docId)
        let insertAt = max(1, endIndex - 1)
        let sectionBlocks = [NoteBlock.heading(payload.title)] + payload.blocks
        try await batchUpdate(token: token, docId: docId,
                              requests: Self.contentRequests(payload: payload, blocks: sectionBlocks,
                                                             startIndex: insertAt, leadingNewlines: 1))
        return result(for: docId)
    }

    // MARK: Drive + Docs primitives

    private func createDocument(token: String, name: String, folderId: String?) async throws -> String {
        var request = URLRequest(url: URL(staticString: "https://www.googleapis.com/drive/v3/files"))
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
        guard var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files") else {
            throw DestinationError.network("Could not build the Drive search URL.")
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id)"),
            URLQueryItem(name: "pageSize", value: "1")
        ]
        guard let url = components.url else {
            throw DestinationError.network("Could not build the Drive search URL.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
        struct FileList: Decodable { struct File: Decodable { let id: String }; let files: [File] }
        return (try? JSONDecoder().decode(FileList.self, from: data))?.files.first?.id
    }

    private func batchUpdate(token: String, docId: String, requests: [[String: Any]]) async throws {
        guard !requests.isEmpty else { return }
        guard let url = URL(string: "https://docs.googleapis.com/v1/documents/\(docId):batchUpdate") else {
            throw DestinationError.network("Could not build the Google Docs update URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["requests": requests])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
    }

    // MARK: Content -> batchUpdate requests

    /// Builds the batchUpdate requests for a payload's content. Uses the
    /// structured `blocks` when present (native headings, bullets, and
    /// checkboxes); otherwise inserts the flattened text.
    static func contentRequests(payload: DestinationPayload, blocks: [NoteBlock],
                                startIndex: Int, leadingNewlines: Int = 0) -> [[String: Any]] {
        guard !blocks.isEmpty else {
            let text = String(repeating: "\n", count: leadingNewlines) + flattenedText(payload)
            guard !text.isEmpty else { return [] }
            return [["insertText": ["text": text, "location": ["index": startIndex]]]]
        }
        return batchRequests(blocks: blocks, startIndex: startIndex, leadingNewlines: leadingNewlines)
    }

    /// Inserts the blocks as text in one request, then applies native paragraph
    /// formatting over computed ranges: headings as HEADING_2, bullets and
    /// checkboxes via bullet presets, and a strikethrough over completed items
    /// (the Docs API can't pre-tick a checkbox, so a strike mirrors how
    /// reMarkable shows a checked item). Indices are UTF-16 offsets from the
    /// single insert, so no request shifts another's range.
    static func batchRequests(blocks: [NoteBlock], startIndex: Int, leadingNewlines: Int = 0) -> [[String: Any]] {
        var text = String(repeating: "\n", count: leadingNewlines)
        var cursor = startIndex + leadingNewlines
        var formatting: [[String: Any]] = []

        for block in blocks {
            let line = lineText(for: block)
            let length = line.utf16.count
            let paragraphRange: [String: Any] = ["startIndex": cursor, "endIndex": cursor + length + 1]
            switch block {
            case .heading:
                formatting.append(["updateParagraphStyle": [
                    "range": paragraphRange,
                    "paragraphStyle": ["namedStyleType": "HEADING_2"],
                    "fields": "namedStyleType"
                ]])
            case .bullet:
                formatting.append(["createParagraphBullets": [
                    "range": paragraphRange, "bulletPreset": "BULLET_DISC_CIRCLE_SQUARE"
                ]])
            case .checkbox(_, let checked):
                formatting.append(["createParagraphBullets": [
                    "range": paragraphRange, "bulletPreset": "BULLET_CHECKBOX"
                ]])
                if checked, length > 0 {
                    formatting.append(["updateTextStyle": [
                        "range": ["startIndex": cursor, "endIndex": cursor + length],
                        "textStyle": ["strikethrough": true],
                        "fields": "strikethrough"
                    ]])
                }
            case .paragraph, .mermaid:
                break
            }
            text += line + "\n"
            cursor += length + 1
        }

        var requests: [[String: Any]] = [["insertText": ["text": text, "location": ["index": startIndex]]]]
        requests.append(contentsOf: formatting)
        return requests
    }

    /// The single-paragraph text for a block (the checkbox/bullet glyph is a
    /// paragraph property, not text). Mermaid is labelled, since Docs has no
    /// diagram rendering.
    private static func lineText(for block: NoteBlock) -> String {
        switch block {
        case .heading(let text), .paragraph(let text), .bullet(let text):
            return text
        case .checkbox(let text, _):
            return text
        case .mermaid(let source):
            return "[Mermaid diagram]\n\(source)"
        }
    }

    private static func flattenedText(_ payload: DestinationPayload) -> String {
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
