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
        XCTAssertEqual(q["expansions"], XAPIClient.expansions)
        XCTAssertTrue(q["expansions"]?.contains("attachments.media_keys") == true)
        XCTAssertTrue(q["tweet.fields"]?.contains("created_at") == true)
        XCTAssertTrue(q["tweet.fields"]?.contains("entities") == true)
        XCTAssertTrue(q["tweet.fields"]?.contains("attachments") == true)
        XCTAssertEqual(q["media.fields"], XAPIClient.mediaFields)
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

    // MARK: Thread expansion URLs

    func test_threadSearchURL_targets_recent_search_with_self_reply_query() throws {
        let url = try XAPIClient.threadSearchURL(conversationId: "123", authorId: "u1")
        XCTAssertEqual(url.path, "/2/tweets/search/recent")
        let q = queryItems(url)
        // from: scopes to the author, to: keeps only replies to their own
        // tweets — so third-party replies and the root never come back.
        XCTAssertEqual(q["query"], "conversation_id:123 from:u1 to:u1")
        XCTAssertEqual(q["max_results"], "100")
        XCTAssertEqual(q["tweet.fields"], XAPIClient.tweetFields)
        XCTAssertEqual(q["expansions"], XAPIClient.expansions)
        XCTAssertEqual(q["user.fields"], XAPIClient.userFields)
    }

    func test_tweetLookupURL_uses_plural_ids_endpoint() throws {
        let url = try XAPIClient.tweetLookupURL(ids: ["123", "456"])
        XCTAssertEqual(url.path, "/2/tweets")
        let q = queryItems(url)
        XCTAssertEqual(q["ids"], "123,456")
        XCTAssertEqual(q["tweet.fields"], XAPIClient.tweetFields)
        XCTAssertEqual(q["expansions"], XAPIClient.expansions)
        XCTAssertEqual(q["user.fields"], XAPIClient.userFields)
    }

    func test_parseTimeline_parses_search_envelope() throws {
        // /2/tweets/search/recent answers with the same envelope as the
        // timeline endpoints, so the one parser covers both.
        let json = #"""
        {
          "data": [
            {"id": "112", "text": "part two", "created_at": "2026-06-20T12:05:00.000Z",
             "author_id": "u1", "conversation_id": "111",
             "referenced_tweets": [{"type": "replied_to", "id": "111"}]}
          ],
          "includes": {"users": [{"id": "u1", "username": "jack", "name": "Jack D"}]},
          "meta": {"result_count": 1}
        }
        """#
        let page = try XAPIClient.parseTimeline(Data(json.utf8), stream: .bookmarks)
        XCTAssertEqual(page.items.map(\.id), ["112"])
        XCTAssertEqual(page.items[0].conversationId, "111")
        XCTAssertEqual(page.items[0].author.username, "jack")
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

    func test_parseTimeline_expands_tco_links_in_text() throws {
        // The display text carries the resolved link, not the t.co shortener.
        let json = #"""
        {"data": [{
          "id": "7", "text": "read this https://t.co/abc now",
          "created_at": "2026-01-01T00:00:00.000Z", "author_id": "u1",
          "entities": {"urls": [
            {"url": "https://t.co/abc", "expanded_url": "https://t.co/abc",
             "unwound_url": "https://example.com/article"}
          ]}
        }]}
        """#
        let page = try XAPIClient.parseTimeline(Data(json.utf8), stream: .bookmarks)
        XCTAssertEqual(page.items.first?.text, "read this https://example.com/article now")
    }

    func test_parseTimeline_strips_media_permalinks_and_collects_media_urls() throws {
        // A photo tweet: the trailing t.co points at the tweet's own /photo/1
        // page, so it's dropped from the text; the actual image URLs arrive via
        // includes.media (photos by url, videos by their preview frame).
        let json = #"""
        {
          "data": [{
            "id": "8", "text": "sunset pics https://t.co/img",
            "created_at": "2026-01-01T00:00:00.000Z", "author_id": "u1",
            "attachments": {"media_keys": ["m1", "m2"]},
            "entities": {"urls": [
              {"url": "https://t.co/img", "expanded_url": "https://x.com/jack/status/8/photo/1"}
            ]}
          }],
          "includes": {
            "users": [{"id": "u1", "username": "jack", "name": "Jack"}],
            "media": [
              {"media_key": "m1", "type": "photo", "url": "https://pbs.twimg.com/media/one.jpg"},
              {"media_key": "m2", "type": "video", "preview_image_url": "https://pbs.twimg.com/media/two-frame.jpg"}
            ]
          }
        }
        """#
        let page = try XAPIClient.parseTimeline(Data(json.utf8), stream: .bookmarks)
        XCTAssertEqual(page.items.first?.text, "sunset pics")
        XCTAssertEqual(page.items.first?.mediaURLs.map(\.absoluteString),
                       ["https://pbs.twimg.com/media/one.jpg", "https://pbs.twimg.com/media/two-frame.jpg"])
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
