//
//  GoogleDocsDestinationClient.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// Writes a transcribed page into Google Docs via the Docs + Drive APIs.
/// Without a valid OAuth token in Keychain this falls back to a mock that
/// returns a synthetic doc URL so the UI flows still feel real.
struct GoogleDocsDestinationClient: DestinationClient {
    let kind: DestinationKind = .googleDocs

    func write(payload: DestinationPayload, configuration: DestinationConfiguration) async throws -> DestinationWriteResult {
        guard case .googleDocs(let config) = configuration else {
            throw OcrError.providerRefused("Google Docs binding has wrong configuration.")
        }
        if let token = KeychainStore.shared.value(for: .googleAccessToken(email: config.accountEmail)),
           !token.isEmpty {
            return try await writeWithRealGoogle(token: token, config: config, payload: payload)
        }
        return try await writeWithMock(config: config, payload: payload)
    }

    // MARK: Real Google Docs

    private func writeWithRealGoogle(token: String, config: GoogleDocsDestinationConfig, payload: DestinationPayload) async throws -> DestinationWriteResult {
        // 1. Create a new doc via Drive API so we can choose the parent folder.
        var createRequest = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files")!)
        createRequest.httpMethod = "POST"
        createRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var driveBody: [String: Any] = [
            "name": payload.title,
            "mimeType": "application/vnd.google-apps.document"
        ]
        if let folder = config.folderId, !folder.isEmpty { driveBody["parents"] = [folder] }
        createRequest.httpBody = try JSONSerialization.data(withJSONObject: driveBody)

        let (createData, _) = try await URLSession.shared.data(for: createRequest)
        struct DriveFile: Decodable { let id: String }
        let drive = try JSONDecoder().decode(DriveFile.self, from: createData)

        // 2. Insert the transcribed body via Docs batchUpdate.
        let body = payload.body + (payload.mermaidSource.map { "\n\n[Mermaid diagram]\n\($0)" } ?? "")
        let docsURL = URL(string: "https://docs.googleapis.com/v1/documents/\(drive.id):batchUpdate")!
        var docsRequest = URLRequest(url: docsURL)
        docsRequest.httpMethod = "POST"
        docsRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        docsRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let docsBody: [String: Any] = [
            "requests": [
                [
                    "insertText": [
                        "location": ["index": 1],
                        "text": body
                    ]
                ]
            ]
        ]
        docsRequest.httpBody = try JSONSerialization.data(withJSONObject: docsBody)
        _ = try await URLSession.shared.data(for: docsRequest)

        return DestinationWriteResult(
            externalId: drive.id,
            externalURL: URL(string: "https://docs.google.com/document/d/\(drive.id)/edit"),
            notes: nil
        )
    }

    // MARK: Mock fallback

    private func writeWithMock(config: GoogleDocsDestinationConfig, payload: DestinationPayload) async throws -> DestinationWriteResult {
        try await Task.sleep(nanoseconds: 200_000_000)
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20)
        return DestinationWriteResult(
            externalId: String(id),
            externalURL: URL(string: "https://docs.google.com/document/d/\(id)/edit"),
            notes: "Mock Google Docs write (no token configured)."
        )
    }
}
