//
//  PolarLicenseClient.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Polar (polar.sh) license-key client. The customer-portal license-key
//  endpoints need no auth — the key plus the public organization id are the
//  whole request — so entitlement works with no server of our own. Stateless and
//  Sendable; the caller (EntitlementManager) owns persistence of the key and
//  activation id. Pure parsing lives in static helpers so it unit-tests without
//  the network, mirroring `XAPIClient`.
//

import Foundation

struct PolarLicenseClient: LicenseProvider {
    private let organizationId: String
    private let session: URLSession
    private let baseURL: URL

    init(organizationId: String = AuthSecrets.polarOrganizationId,
         session: URLSession = .shared,
         baseURL: URL = URL(staticString: "https://api.polar.sh")) {
        self.organizationId = organizationId
        self.session = session
        self.baseURL = baseURL
    }

    // MARK: LicenseProvider

    func activate(key: String, deviceLabel: String) async throws -> LicenseActivation {
        let data = try await post(path: "v1/customer-portal/license-keys/activate", body: [
            "key": key,
            "organization_id": organizationId,
            "label": deviceLabel
        ])
        return try Self.decodeActivation(data)
    }

    func validate(key: String, activationId: String?) async throws -> LicenseStatus {
        var body = ["key": key, "organization_id": organizationId]
        if let activationId { body["activation_id"] = activationId }
        let data = try await post(path: "v1/customer-portal/license-keys/validate", body: body)
        return try Self.decodeStatus(data)
    }

    func deactivate(key: String, activationId: String) async throws {
        _ = try await post(path: "v1/customer-portal/license-keys/deactivate", body: [
            "key": key,
            "organization_id": organizationId,
            "activation_id": activationId
        ])
    }

    // MARK: Networking

    private func post(path: String, body: [String: String]) async throws -> Data {
        guard !organizationId.isEmpty else { throw LicenseError.notConfigured }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, data: data)
        return data
    }

    /// Maps an HTTP status to a semantic error, leaving 2xx to the parser. 404 is
    /// an unknown key; an activation-limit rejection (403/422 whose body mentions
    /// the activation limit) is called out so the paywall can guide the user.
    static func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300:
            return
        case 404:
            throw LicenseError.invalidKey
        case 403, 422:
            let message = errorMessage(data)
            let lower = message.lowercased()
            if lower.contains("activation") && lower.contains("limit") {
                throw LicenseError.activationLimitReached
            }
            throw LicenseError.requestFailed(status: http.statusCode, message: message)
        default:
            throw LicenseError.requestFailed(status: http.statusCode, message: errorMessage(data))
        }
    }

    // MARK: Pure parsing (unit-tested)

    /// Decodes a validate response (the license key object at the top level).
    static func decodeStatus(_ data: Data) throws -> LicenseStatus {
        guard let payload = try? JSONDecoder().decode(KeyPayload.self, from: data) else {
            throw LicenseError.invalidResponse("Couldn't read Polar's response.")
        }
        return status(from: payload)
    }

    /// Decodes an activate response: the activation `id` plus the nested
    /// `license_key` status (falling back to a top-level key shape if not nested).
    static func decodeActivation(_ data: Data) throws -> LicenseActivation {
        guard let envelope = try? JSONDecoder().decode(ActivationPayload.self, from: data) else {
            throw LicenseError.invalidResponse("Couldn't read the activation from Polar's response.")
        }
        let keyPayload = envelope.license_key ?? (try? JSONDecoder().decode(KeyPayload.self, from: data)) ?? KeyPayload()
        return LicenseActivation(activationId: envelope.id, status: status(from: keyPayload))
    }

    static func status(from payload: KeyPayload) -> LicenseStatus {
        let state = LicenseStatus.State(rawValue: payload.status ?? "") ?? .unknown
        let expiresAt = payload.expires_at.flatMap(parseDate)
        return LicenseStatus(state: state, expiresAt: expiresAt, customerId: payload.customer?.id)
    }

    /// Best-effort extraction of a human message from a Polar error body
    /// (`{detail}`, `{error}`, or FastAPI's `{detail: [{msg}]}`).
    static func errorMessage(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8) ?? ""
            return text.isEmpty ? "Unknown error" : String(text.prefix(200))
        }
        if let detail = object["detail"] as? String { return detail }
        if let error = object["error"] as? String { return error }
        if let list = object["detail"] as? [[String: Any]], let msg = list.first?["msg"] as? String { return msg }
        return "Unknown error"
    }

    private static func parseDate(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return withFraction.date(from: raw) ?? plain.date(from: raw)
    }

    // Decoding shapes mirroring Polar's license-key payloads.
    struct KeyPayload: Decodable {
        var status: String?
        var expires_at: String?
        var customer: CustomerPayload?
    }
    struct CustomerPayload: Decodable {
        var id: String?
    }
    private struct ActivationPayload: Decodable {
        let id: String
        let license_key: KeyPayload?
    }
}
