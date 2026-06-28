//
//  XAuthServiceTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  X OAuth 2.0 PKCE: authorize-URL shape, per-stream scope minimization, and
//  token-response parsing.
//

import XCTest
@testable import SyncBar

@MainActor
final class XAuthServiceTests: XCTestCase {

    private func queryItems(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            out[item.name] = item.value
        }
        return out
    }

    // MARK: Authorize URL

    func test_authorizeURL_carries_pkce_params() {
        let url = XAuthService.authorizeURL(clientId: "x-client", state: "st",
                                            challenge: "chal", scope: "tweet.read users.read offline.access")
        XCTAssertEqual(url.host, "twitter.com")
        XCTAssertEqual(url.path, "/i/oauth2/authorize")
        let q = queryItems(url)
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["client_id"], "x-client")
        XCTAssertEqual(q["redirect_uri"], "syncbar://oauth/x")
        XCTAssertEqual(q["state"], "st")
        XCTAssertEqual(q["code_challenge"], "chal")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["scope"], "tweet.read users.read offline.access")
    }

    // MARK: Scope minimization

    func test_scopes_for_posts_requests_no_content_specific_scope() {
        let scope = XAuthService.scopes(for: [.posts])
        XCTAssertEqual(scope, "tweet.read users.read offline.access")
        XCTAssertFalse(scope.contains("bookmark.read"))
        XCTAssertFalse(scope.contains("like.read"))
    }

    func test_scopes_for_bookmarks_adds_bookmark_read() {
        let scope = XAuthService.scopes(for: [.bookmarks])
        XCTAssertTrue(scope.contains("bookmark.read"))
        XCTAssertFalse(scope.contains("like.read"))
        XCTAssertTrue(scope.contains("offline.access"))
    }

    func test_scopes_for_likes_adds_like_read() {
        XCTAssertTrue(XAuthService.scopes(for: [.likes]).contains("like.read"))
    }

    func test_scopes_for_all_streams_are_deduped_and_baseline_first() {
        let scope = XAuthService.scopes(for: XStream.allCases)
        let parts = scope.split(separator: " ").map(String.init)
        // Baseline scopes lead, both content scopes present, nothing duplicated.
        XCTAssertEqual(Array(parts.prefix(3)), ["tweet.read", "users.read", "offline.access"])
        XCTAssertTrue(parts.contains("bookmark.read"))
        XCTAssertTrue(parts.contains("like.read"))
        XCTAssertEqual(parts.count, Set(parts).count)
    }

    // MARK: Token parsing

    func test_parseTokenResponse_reads_fields() throws {
        let json = #"{"access_token":"at","refresh_token":"rt","expires_in":7200,"scope":"tweet.read","token_type":"bearer"}"#
        let token = try XTokens.parseTokenResponse(Data(json.utf8))
        XCTAssertEqual(token.access_token, "at")
        XCTAssertEqual(token.refresh_token, "rt")
        XCTAssertEqual(token.expires_in, 7200)
    }

    func test_parseTokenResponse_rejects_empty_access() {
        XCTAssertThrowsError(try XTokens.parseTokenResponse(Data(#"{"access_token":""}"#.utf8)))
    }
}
