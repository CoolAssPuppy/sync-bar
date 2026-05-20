//
//  LinearAuthServiceTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

@MainActor
final class LinearAuthServiceTests: XCTestCase {

    private func queryItems(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            out[item.name] = item.value
        }
        return out
    }

    func test_authorizeURL_carries_oauth_parameters() {
        let url = LinearAuthService.authorizeURL(clientId: "client-123", state: "state-xyz")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "linear.app")
        let q = queryItems(url)
        XCTAssertEqual(q["client_id"], "client-123")
        XCTAssertEqual(q["redirect_uri"], "syncbar://oauth/linear")
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["scope"], "read,write")
        XCTAssertEqual(q["state"], "state-xyz")
        XCTAssertEqual(q["actor"], "user")
    }

    func test_parseAccessToken_returns_token() throws {
        let json = #"{"access_token":"lin_oauth_abc","token_type":"Bearer","expires_in":315360000,"scope":"read,write"}"#
        XCTAssertEqual(try LinearAuthService.parseAccessToken(Data(json.utf8)), "lin_oauth_abc")
    }

    func test_parseAccessToken_rejects_empty_token() {
        let json = #"{"access_token":"","token_type":"Bearer"}"#
        XCTAssertThrowsError(try LinearAuthService.parseAccessToken(Data(json.utf8)))
    }

    func test_parseTeams_maps_nodes_to_accounts_with_org() throws {
        let json = #"""
        {"data":{"viewer":{"organization":{"name":"Acme"}},"teams":{"nodes":[
          {"id":"t1","name":"Engineering"},{"id":"t2","name":"Growth"}]}}}
        """#
        let accounts = try LinearAuthService.parseTeams(Data(json.utf8))
        XCTAssertEqual(accounts.map(\.id), ["t1", "t2"])
        XCTAssertEqual(accounts.map(\.name), ["Engineering", "Growth"])
        XCTAssertTrue(accounts.allSatisfy { $0.organizationName == "Acme" })
    }

    func test_parseTeams_throws_when_data_missing() {
        let json = #"{"errors":[{"message":"unauthorized"}]}"#
        XCTAssertThrowsError(try LinearAuthService.parseTeams(Data(json.utf8)))
    }
}
