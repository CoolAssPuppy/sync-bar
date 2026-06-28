//
//  XAPIClientTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Pure coverage of the X API v2 client: request-URL building (including the
//  since_id gating that distinguishes bookmarks from the timeline endpoints) and
//  the timeline → normalized-content parsing.
//

import XCTest
@testable import SyncBar

final class XAPIClientTests: XCTestCase {

    private func queryItems(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            out[item.name] = item.value
        }
        return out
    }

    // MARK: URL building

    func test_pageURL_targets_the_stream_endpoint() throws {
        let bookmarks = try XAPIClient.pageURL(stream: .bookmarks, userId: "42", paginationToken: nil, sinceId: nil, maxResults: 100)
        XCTAssertEqual(bookmarks.path, "/2/users/42/bookmarks")
        let likes = try XAPIClient.pageURL(stream: .likes, userId: "42", paginationToken: nil, sinceId: nil, maxResults: 100)
        XCTAssertEqual(likes.path, "/2/users/42/liked_tweets")
        let posts = try XAPIClient.pageURL(stream: .posts, userId: "42", paginationToken: nil, sinceId: nil, maxResults: 100)
        XCTAssertEqual(posts.path, "/2/users/42/tweets")
    }

    func test_pageURL_carries_fields_and_expansions() throws {
        let url = try XAPIClient.pageURL(stream: .posts, userId: "42", paginationToken: nil, sinceId: nil, maxResults: 50)
        let q = queryItems(url)
        XCTAssertEqual(q["max_results"], "50")
        XCTAssertEqual(q["expansions"], "author_id")
        XCTAssertTrue(q["tweet.fields"]?.contains("created_at") == true)
        XCTAssertTrue(q["tweet.fields"]?.contains("entities") == true)
        XCTAssertTrue(q["user.fields"]?.contains("username") == true)
    }

    func test_pageURL_includes_pagination_token() throws {
        let url = try XAPIClient.pageURL(stream: .posts, userId: "42", paginationToken: "PAGE2", sinceId: nil, maxResults: 100)
        XCTAssertEqual(queryItems(url)["pagination_token"], "PAGE2")
    }

    func test_pageURL_sends_since_id_only_for_supporting_streams() throws {
        // Posts/likes honor since_id …
        let posts = try XAPIClient.pageURL(stream: .posts, userId: "42", paginationToken: nil, sinceId: "999", maxResults: 100)
        XCTAssertEqual(queryItems(posts)["since_id"], "999")
        // … bookmarks do not, so it must be omitted there.
        let bookmarks = try XAPIClient.pageURL(stream: .bookmarks, userId: "42", paginationToken: nil, sinceId: "999", maxResults: 100)
        XCTAssertNil(queryItems(bookmarks)["since_id"])
    }

    // MARK: Parsing

    private let sampleTimeline = #"""
    {
      "data": [
        {
          "id": "111",
          "text": "Hello world\nsecond line",
          "created_at": "2026-06-20T12:00:00.000Z",
          "author_id": "u1",
          "conversation_id": "111",
          "public_metrics": {"like_count": 5, "retweet_count": 2},
          "entities": {"urls": [
            {"expanded_url": "https://t.co/x", "unwound_url": "https://example.com/a"},
            {"expanded_url": "https://example.com/a"}
          ]},
          "referenced_tweets": [{"type": "replied_to", "id": "100"}]
        },
        {
          "id": "110",
          "text": "Second tweet",
          "created_at": "2026-06-19T08:30:00.000Z",
          "author_id": "u1"
        }
      ],
      "includes": {"users": [{"id": "u1", "username": "jack", "name": "Jack D"}]},
      "meta": {"next_token": "NEXT", "result_count": 2}
    }
    """#

    func test_parseTimeline_normalizes_tweets() throws {
        let page = try XAPIClient.parseTimeline(Data(sampleTimeline.utf8), stream: .bookmarks)
        XCTAssertEqual(page.nextToken, "NEXT")
        XCTAssertEqual(page.items.map(\.id), ["111", "110"])

        let first = page.items[0]
        XCTAssertEqual(first.stream, .bookmarks)
        XCTAssertEqual(first.text, "Hello world\nsecond line")
        XCTAssertEqual(first.author.username, "jack")
        XCTAssertEqual(first.author.displayName, "Jack D")
        XCTAssertEqual(first.author.handle, "@jack")
        XCTAssertEqual(first.canonicalURL?.absoluteString, "https://x.com/jack/status/111")
        XCTAssertEqual(first.conversationId, "111")
        XCTAssertEqual(first.referencedTweetIds, ["100"])
        XCTAssertEqual(first.metrics["like_count"], 5)
    }

    func test_parseTimeline_prefers_unwound_url_and_dedupes_links() throws {
        let page = try XAPIClient.parseTimeline(Data(sampleTimeline.utf8), stream: .bookmarks)
        // The unwound (resolved) URL wins over the t.co shortlink, and the
        // duplicate expanded_url is collapsed.
        XCTAssertEqual(page.items[0].outboundLinks.map(\.absoluteString), ["https://example.com/a"])
    }

    func test_parseTimeline_handles_empty_page() throws {
        let json = #"{"data": [], "meta": {"result_count": 0}}"#
        let page = try XAPIClient.parseTimeline(Data(json.utf8), stream: .likes)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.nextToken)
    }

    func test_parseTimeline_throws_on_errors_only_response() {
        let json = #"{"errors": [{"title": "Unauthorized", "detail": "bad token"}]}"#
        XCTAssertThrowsError(try XAPIClient.parseTimeline(Data(json.utf8), stream: .posts))
    }

    func test_parseTimeline_tolerates_missing_author() throws {
        // A tweet with no matching include still normalizes (blank author).
        let json = #"{"data": [{"id": "5", "text": "orphan", "created_at": "2026-01-01T00:00:00.000Z"}]}"#
        let page = try XAPIClient.parseTimeline(Data(json.utf8), stream: .posts)
        XCTAssertEqual(page.items.first?.id, "5")
        XCTAssertEqual(page.items.first?.author.username, "")
        XCTAssertEqual(page.items.first?.canonicalURL?.absoluteString, "https://x.com/i/web/status/5")
    }
}
