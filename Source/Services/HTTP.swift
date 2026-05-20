//
//  HTTP.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// Lightweight HTTP helpers shared across every external service client.
/// Centralizes the "validate status, surface 401/429 specially, decode JSON"
/// dance that was duplicated in five places before.
enum HTTP {
    static let session: URLSession = .shared

    enum Failure: LocalizedError {
        case unauthorized(String)
        case rateLimited
        case server(status: Int, snippet: String)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized(let reason): return reason
            case .rateLimited:              return "Server throttled us. Try again in a minute."
            case .server(let status, let snippet): return "HTTP \(status): \(snippet)"
            case .decoding(let msg):        return "Decode failed: \(msg)"
            }
        }
    }

    /// Sends a POST with a JSON body and decodes the response, validating
    /// status along the way.
    static func postJSON<R: Decodable>(
        url: URL,
        body: Any,
        headers: [String: String] = [:],
        decode: R.Type
    ) async throws -> R {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        do {
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            throw Failure.decoding(error.localizedDescription)
        }
    }

    /// Sends a GET and decodes the JSON response.
    static func getJSON<R: Decodable>(
        url: URL,
        headers: [String: String] = [:],
        decode: R.Type
    ) async throws -> R {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        do {
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            throw Failure.decoding(error.localizedDescription)
        }
    }

    /// Maps HTTP status to a domain-friendly throw. Callers translate
    /// these into their own error type if they want (NotionError,
    /// DestinationError, OcrError).
    static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw Failure.unauthorized("Authorization rejected by server.")
        case 429:      throw Failure.rateLimited
        default:
            let snippet = String(data: data, encoding: .utf8)?.prefix(200).description ?? "HTTP \(http.statusCode)"
            throw Failure.server(status: http.statusCode, snippet: snippet)
        }
    }
}
