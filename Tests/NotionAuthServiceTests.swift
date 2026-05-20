//
//  NotionAuthServiceTests.swift
//  SyncNerdsTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncNerds

@MainActor
final class NotionAuthServiceTests: XCTestCase {

    private func queryItems(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            out[item.name] = item.value
        }
        return out
    }

    func test_authorizeURL_carries_oauth_parameters() {
        let url = NotionAuthService.authorizeURL(clientId: "notion-client", state: "st8")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "api.notion.com")
        XCTAssertEqual(url.path, "/v1/oauth/authorize")
        let q = queryItems(url)
        XCTAssertEqual(q["client_id"], "notion-client")
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["owner"], "user")
        XCTAssertEqual(q["redirect_uri"], "http://localhost:53117/oauth/notion")
        XCTAssertEqual(q["state"], "st8")
    }

    func test_parseWorkspace_maps_token_response() throws {
        let json = #"""
        {"access_token":"secret_abc","token_type":"bearer","bot_id":"bot1",
         "workspace_id":"ws1","workspace_name":"Acme","workspace_icon":"https://x/icon.png",
         "owner":{"type":"user"}}
        """#
        let result = try NotionAuthService.parseWorkspace(Data(json.utf8))
        XCTAssertEqual(result.accessToken, "secret_abc")
        XCTAssertEqual(result.workspace.id, "ws1")
        XCTAssertEqual(result.workspace.workspaceName, "Acme")
        XCTAssertEqual(result.workspace.workspaceIcon, "https://x/icon.png")
        XCTAssertEqual(result.workspace.botId, "bot1")
    }

    func test_parseWorkspace_rejects_incomplete_response() {
        let json = #"{"access_token":"","workspace_id":""}"#
        XCTAssertThrowsError(try NotionAuthService.parseWorkspace(Data(json.utf8)))
    }

    func test_loopback_parses_query_from_request_line() {
        let request = "GET /oauth/notion?code=abc&state=xyz HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let items = LoopbackOAuthServer.parseQuery(fromRequestLine: request)
        XCTAssertEqual(items["code"], "abc")
        XCTAssertEqual(items["state"], "xyz")
    }

    func test_loopback_returns_empty_for_no_query() {
        let items = LoopbackOAuthServer.parseQuery(fromRequestLine: "GET /oauth/notion HTTP/1.1\r\n")
        XCTAssertTrue(items.isEmpty)
    }
}
