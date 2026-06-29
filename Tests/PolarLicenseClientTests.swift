//
//  PolarLicenseClientTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Coverage of the Polar license client: pure parsing of activate/validate
//  responses, error-body extraction, and the network status-code mapping
//  (driven through the shared StubURLProtocol).
//

import XCTest
@testable import SyncBar

final class PolarLicenseClientTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func client(session: URLSession) -> PolarLicenseClient {
        PolarLicenseClient(organizationId: "org-123", session: session,
                           baseURL: URL(staticString: "https://api.polar.test"))
    }

    // MARK: Pure parsing

    func test_validate_response_maps_granted_with_expiry_and_customer() throws {
        let json = Data(#"""
        { "id": "lk1", "status": "granted", "expires_at": "2026-12-31T00:00:00Z",
          "customer": { "id": "cus_99" } }
        """#.utf8)
        let status = try PolarLicenseClient.decodeStatus(json)
        XCTAssertEqual(status.state, .granted)
        XCTAssertTrue(status.isGranted)
        XCTAssertEqual(status.customerId, "cus_99")
        XCTAssertNotNil(status.expiresAt)
    }

    func test_validate_response_maps_revoked_and_disabled() throws {
        XCTAssertEqual(try PolarLicenseClient.decodeStatus(Data(#"{"status":"revoked"}"#.utf8)).state, .revoked)
        XCTAssertEqual(try PolarLicenseClient.decodeStatus(Data(#"{"status":"disabled"}"#.utf8)).state, .disabled)
    }

    func test_unrecognized_status_maps_to_unknown_not_granted() throws {
        let status = try PolarLicenseClient.decodeStatus(Data(#"{"status":"mystery"}"#.utf8))
        XCTAssertEqual(status.state, .unknown)
        XCTAssertFalse(status.isGranted)
    }

    func test_activate_response_reads_activation_id_and_nested_status() throws {
        let json = Data(#"""
        { "id": "act_abc", "license_key": { "status": "granted", "expires_at": null,
          "customer": { "id": "cus_7" } } }
        """#.utf8)
        let activation = try PolarLicenseClient.decodeActivation(json)
        XCTAssertEqual(activation.activationId, "act_abc")
        XCTAssertEqual(activation.status.state, .granted)
        XCTAssertEqual(activation.status.customerId, "cus_7")
        XCTAssertNil(activation.status.expiresAt)
    }

    func test_error_message_reads_detail_error_and_validation_shapes() {
        XCTAssertEqual(PolarLicenseClient.errorMessage(Data(#"{"detail":"nope"}"#.utf8)), "nope")
        XCTAssertEqual(PolarLicenseClient.errorMessage(Data(#"{"error":"bad"}"#.utf8)), "bad")
        XCTAssertEqual(PolarLicenseClient.errorMessage(Data(#"{"detail":[{"msg":"field required"}]}"#.utf8)), "field required")
    }

    // MARK: Network behavior

    func test_validate_sends_key_and_org_id_to_the_validate_endpoint() async throws {
        let captured = BodyCapture()
        StubURLProtocol.handler = { request, body in
            captured.record(path: request.url?.path ?? "", body: body)
            return (200, Data(#"{"status":"granted"}"#.utf8))
        }
        let status = try await client(session: makeSession()).validate(key: "KEY-1", activationId: "act-1")
        XCTAssertTrue(status.isGranted)
        XCTAssertEqual(captured.path, "/v1/customer-portal/license-keys/validate")
        XCTAssertEqual(captured.bodyField("key"), "KEY-1")
        XCTAssertEqual(captured.bodyField("organization_id"), "org-123")
        XCTAssertEqual(captured.bodyField("activation_id"), "act-1")
    }

    func test_unknown_key_surfaces_invalidKey() async {
        StubURLProtocol.handler = { _, _ in (404, Data(#"{"detail":"ResourceNotFound"}"#.utf8)) }
        await assertThrows(LicenseError.invalidKey) {
            _ = try await self.client(session: self.makeSession()).validate(key: "X", activationId: nil)
        }
    }

    func test_activation_limit_surfaces_activationLimitReached() async {
        StubURLProtocol.handler = { _, _ in
            (403, Data(#"{"detail":"License key activation limit already reached."}"#.utf8))
        }
        await assertThrows(LicenseError.activationLimitReached) {
            _ = try await self.client(session: self.makeSession()).activate(key: "X", deviceLabel: "Mac")
        }
    }

    func test_missing_org_id_surfaces_notConfigured() async {
        let unconfigured = PolarLicenseClient(organizationId: "", session: makeSession(),
                                              baseURL: URL(staticString: "https://api.polar.test"))
        await assertThrows(LicenseError.notConfigured) {
            _ = try await unconfigured.validate(key: "X", activationId: nil)
        }
    }

    // MARK: Helpers

    private func assertThrows(_ expected: LicenseError, _ body: () async throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("Expected \(expected) to be thrown", file: file, line: line)
        } catch let error as LicenseError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected LicenseError.\(expected), got \(error)", file: file, line: line)
        }
    }
}

/// Captures the request path and JSON body from a stubbed request for assertion.
private final class BodyCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _path = ""
    private var _body: [String: Any] = [:]

    func record(path: String, body: Data) {
        lock.lock(); defer { lock.unlock() }
        _path = path
        _body = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }
    var path: String { lock.lock(); defer { lock.unlock() }; return _path }
    func bodyField(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return _body[key] as? String
    }
}
