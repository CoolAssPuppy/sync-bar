//
//  XSourceClientTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The X source adapter: pure normalization (tweet → SourceItem / NoteContent)
//  and the incremental crawl end-to-end via the stubbed URL session — initial
//  full crawl across pages, then stop-at-already-synced on the next run.
//

import XCTest
@testable import SyncBar

final class XSourceClientTests: XCTestCase {

    // MARK: Pure normalization

    private func sampleTweet(id: String = "111",
                             text: String = "Hello world\nmore detail",
                             createdAt: TimeInterval = 1_700_000_000) -> XContent {
        XContent(
            id: id, stream: .bookmarks, text: text,
            createdAt: Date(timeIntervalSince1970: createdAt),
            author: XAuthor(id: "u1", username: "jack", displayName: "Jack D"),
            canonicalURL: URL(string: "https://x.com/jack/status/\(id)"),
            outboundLinks: [URL(string: "https://example.com")!],
            conversationId: "111", referencedTweetIds: ["100"], metrics: ["like_count": 5])
    }

    func test_makeItem_normalizes_identity_and_metadata() {
        let item = XSourceClient.makeItem(sampleTweet())
        XCTAssertEqual(item.id, "111")
        XCTAssertEqual(item.versionHash, "111", "tweets are immutable, so the id is the version")
        XCTAssertEqual(item.name, "Hello world")
        XCTAssertEqual(item.url?.absoluteString, "https://x.com/jack/status/111")
        XCTAssertEqual(item.metadata["source"], "x")
        XCTAssertEqual(item.metadata["stream"], "bookmarks")
        XCTAssertEqual(item.metadata["author"], "@jack")
        XCTAssertEqual(item.metadata["canonical_url"], "https://x.com/jack/status/111")
        XCTAssertEqual(item.metadata["outbound_links"], "https://example.com")
        XCTAssertEqual(item.metadata["like_count"], "5")
    }

    func test_title_truncates_long_first_line() {
        let long = String(repeating: "a", count: 200)
        let title = XSourceClient.title(for: sampleTweet(text: long))
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertLessThanOrEqual(title.count, 81)
    }

    func test_title_falls_back_for_media_only_tweet() {
        XCTAssertEqual(XSourceClient.title(for: sampleTweet(text: "   ")), "@jack on X")
    }

    func test_blocks_splits_into_paragraphs() {
        XCTAssertEqual(XSourceClient.blocks(from: "a\n\nb"), [.paragraph("a"), .paragraph("b")])
        XCTAssertEqual(XSourceClient.blocks(from: ""), [])
    }

    // MARK: Thread assembly

    func test_threadTweets_orders_root_then_replies_chronologically() {
        let root = sampleTweet(id: "100", text: "root", createdAt: 1_000)
        let anchor = sampleTweet(id: "300", text: "anchor", createdAt: 3_000)
        let early = sampleTweet(id: "200", text: "early reply", createdAt: 2_000)
        let late = sampleTweet(id: "400", text: "late reply", createdAt: 4_000)
        let thread = XSourceClient.threadTweets(anchor: anchor, root: root, replies: [late, early])
        XCTAssertEqual(thread.map(\.id), ["100", "200", "300", "400"])
    }

    func test_threadTweets_ties_break_numerically_by_id() {
        // Same timestamp: ids grow over time, so numeric order wins ("9" < "10").
        let anchor = sampleTweet(id: "9", createdAt: 1_000)
        let reply = sampleTweet(id: "10", createdAt: 1_000)
        let thread = XSourceClient.threadTweets(anchor: anchor, root: nil, replies: [reply])
        XCTAssertEqual(thread.map(\.id), ["9", "10"])
    }

    func test_threadTweets_dedupes_anchor_and_root() {
        let anchor = sampleTweet(id: "100", text: "root is anchor", createdAt: 1_000)
        let reply = sampleTweet(id: "200", createdAt: 2_000)
        // The anchor IS the root, and the search echoed the anchor back too.
        let thread = XSourceClient.threadTweets(anchor: anchor, root: anchor, replies: [reply, anchor])
        XCTAssertEqual(thread.map(\.id), ["100", "200"])
    }

    func test_threadTweets_anchor_only_passthrough() {
        let anchor = sampleTweet()
        XCTAssertEqual(XSourceClient.threadTweets(anchor: anchor, root: nil, replies: []), [anchor])
    }

    func test_threadText_separates_tweets_with_a_rule() {
        let first = sampleTweet(id: "1", text: "one", createdAt: 1_000)
        let second = sampleTweet(id: "2", text: "two\nmore", createdAt: 2_000)
        XCTAssertEqual(XSourceClient.threadText([first, second]), "one\n~~~\ntwo\nmore")
        // A single tweet gets no separator, matching today's body exactly.
        XCTAssertEqual(XSourceClient.threadText([first]), "one")
        // The separator becomes its own paragraph between the tweets' lines.
        XCTAssertEqual(
            XSourceClient.blocks(from: XSourceClient.threadText([first, second])),
            [.paragraph("one"), .paragraph("~~~"), .paragraph("two"), .paragraph("more")])
    }

    // MARK: Crawl (end-to-end via stub)

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeStateStore() -> XSyncStateStore {
        let name = "x.client.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return XSyncStateStore(store: defaults)
    }

    /// An isolated read budget so crawl tests never touch the real defaults.
    private func makeBudget() -> ReadBudget {
        let name = "x.client.budget.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return ReadBudget(defaults: defaults, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
    }

    /// Seeds a long-lived access token so `validAccessToken` returns without a
    /// network refresh, and returns a cleanup closure.
    private func seedToken(accountId: String) -> () -> Void {
        let kc = KeychainStore.shared
        kc.set(value: "test-access", for: .xAccessToken(accountId: accountId))
        kc.set(value: String(Date().timeIntervalSince1970 + 3600), for: .xTokenExpiry(accountId: accountId))
        return {
            kc.delete(key: .xAccessToken(accountId: accountId))
            kc.delete(key: .xRefreshToken(accountId: accountId))
            kc.delete(key: .xTokenExpiry(accountId: accountId))
        }
    }

    private func timelineJSON(ids: [String], nextToken: String?) -> Data {
        let tweets = ids.map { #"{"id":"\#($0)","text":"tweet \#($0)","created_at":"2026-06-20T12:00:00.000Z","author_id":"u1"}"# }
        let meta = nextToken.map { #","meta":{"next_token":"\#($0)"}"# } ?? ""
        let json = #"{"data":[\#(tweets.joined(separator: ","))],"includes":{"users":[{"id":"u1","username":"jack","name":"Jack"}]}\#(meta)}"#
        return Data(json.utf8)
    }

    private func paginationToken(_ request: URLRequest) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "pagination_token" }?.value
    }

    func test_initial_crawl_paginates_every_page() async throws {
        let cleanup = seedToken(accountId: "u1"); defer { cleanup() }
        // Page 1 (newest first): 3,2 → next P2. Page 2: 1 → end.
        StubURLProtocol.handler = { request, _ in
            if self.paginationToken(request) == "P2" {
                return (200, self.timelineJSON(ids: ["1"], nextToken: nil))
            }
            return (200, self.timelineJSON(ids: ["3", "2"], nextToken: "P2"))
        }
        let store = makeStateStore()
        let client = XSourceClient(keychain: .shared, session: makeSession(), stateStore: store, maxPagesPerCrawl: 10, readBudget: makeBudget())
        let config = SourceConfiguration.x(XSourceConfig(accountId: "u1", username: "@jack", stream: .posts))

        let items = try await client.listItems(config: config)
        XCTAssertEqual(items.map(\.id), ["3", "2", "1"])

        let state = store.state(accountId: "u1", stream: .posts)
        XCTAssertFalse(state.isInitialSync)
        XCTAssertEqual(state.newestSyncedId, "3")
        XCTAssertNotNil(state.lastSuccessfulSyncAt)

        // Content for a returned item comes from the per-cycle cache (no refetch).
        let content = try await client.content(for: items[0], config: config)
        XCTAssertEqual(content.blocks, [.paragraph("tweet 3")])
        XCTAssertEqual(content.provider, "x")
    }

    func test_incremental_run_stops_at_already_synced() async throws {
        let cleanup = seedToken(accountId: "u1"); defer { cleanup() }
        let store = makeStateStore()
        // Pretend a prior run synced up to id 2.
        store.recordSuccess(accountId: "u1", stream: .posts, newestId: "2", processedIds: ["2", "1"])

        StubURLProtocol.handler = { _, _ in
            // Newest-first page that overlaps the known cursor at id 2. The
            // next_token would only be followed if the crawl failed to stop at 2;
            // it points back at the same page, so a returned [4,3] proves it
            // stopped at the overlap rather than paging on.
            return (200, self.timelineJSON(ids: ["4", "3", "2", "1"], nextToken: "LOOP"))
        }
        let client = XSourceClient(keychain: .shared, session: makeSession(), stateStore: store, maxPagesPerCrawl: 10, readBudget: makeBudget())
        let config = SourceConfiguration.x(XSourceConfig(accountId: "u1", username: "@jack", stream: .posts))

        let items = try await client.listItems(config: config)
        XCTAssertEqual(items.map(\.id), ["4", "3"], "stops the moment it reaches the synced id 2")
        XCTAssertEqual(store.state(accountId: "u1", stream: .posts).newestSyncedId, "4")
    }

    // MARK: Read-budget accounting (the flat-rate cost ceiling)

    func test_crawl_records_every_billed_read_to_the_budget() async throws {
        let cleanup = seedToken(accountId: "u1"); defer { cleanup() }
        StubURLProtocol.handler = { request, _ in
            if self.paginationToken(request) == "P2" {
                return (200, self.timelineJSON(ids: ["1"], nextToken: nil))
            }
            return (200, self.timelineJSON(ids: ["3", "2"], nextToken: "P2"))
        }
        let budget = makeBudget()
        let client = XSourceClient(keychain: .shared, session: makeSession(), stateStore: makeStateStore(),
                                   maxPagesPerCrawl: 10, readBudget: budget)
        let config = SourceConfiguration.x(XSourceConfig(accountId: "u1", username: "@jack", stream: .posts))

        _ = try await client.listItems(config: config)
        XCTAssertEqual(budget.reads(now: Date()), 3, "all returned posts are charged against the cap")
    }

    func test_reads_are_charged_even_when_a_later_page_throws() async throws {
        let cleanup = seedToken(accountId: "u1"); defer { cleanup() }
        // Page 1 returns two posts; page 2 rate-limits, so listItems throws.
        StubURLProtocol.handler = { request, _ in
            if self.paginationToken(request) == "P2" { return (429, Data("{}".utf8)) }
            return (200, self.timelineJSON(ids: ["3", "2"], nextToken: "P2"))
        }
        let budget = makeBudget()
        let client = XSourceClient(keychain: .shared, session: makeSession(), stateStore: makeStateStore(),
                                   maxPagesPerCrawl: 10, readBudget: budget)
        let config = SourceConfiguration.x(XSourceConfig(accountId: "u1", username: "@jack", stream: .posts))

        do {
            _ = try await client.listItems(config: config)
            XCTFail("expected the rate-limited page to throw")
        } catch {
            // expected
        }
        XCTAssertEqual(budget.reads(now: Date()), 2, "page 1's billed reads are charged even though page 2 failed")
    }

    // MARK: Thread expansion (end-to-end via stub)

    /// Thread-safe tally of the stubbed requests, since expansion must issue
    /// (or provably not issue) extra search/lookup calls.
    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var searches = 0
        private var lookups = 0
        private var lastQuery: String?
        func record(_ request: URLRequest) {
            lock.lock(); defer { lock.unlock() }
            let path = request.url?.path ?? ""
            if path.hasSuffix("/search/recent") {
                searches += 1
                lastQuery = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "query" }?.value
            } else if path.hasSuffix("/2/tweets") {
                lookups += 1
            }
        }
        var searchCount: Int { lock.lock(); defer { lock.unlock() }; return searches }
        var lookupCount: Int { lock.lock(); defer { lock.unlock() }; return lookups }
        var lastSearchQuery: String? { lock.lock(); defer { lock.unlock() }; return lastQuery }
    }

    private func tweetJSON(id: String, conversationId: String? = nil,
                           authorId: String = "u1", minute: Int = 0) -> String {
        let conversation = conversationId.map { #","conversation_id":"\#($0)""# } ?? ""
        let stamp = String(format: "2026-06-20T12:%02d:00.000Z", minute)
        return #"{"id":"\#(id)","text":"tweet \#(id)","created_at":"\#(stamp)","author_id":"\#(authorId)"\#(conversation)}"#
    }

    private func envelope(_ tweets: [String]) -> Data {
        Data(#"{"data":[\#(tweets.joined(separator: ","))],"includes":{"users":[{"id":"u1","username":"jack","name":"Jack"}]}}"#.utf8)
    }

    private func makeExpansionClient(budget: ReadBudget? = nil) -> (XSourceClient, SourceConfiguration) {
        let client = XSourceClient(keychain: .shared, session: makeSession(), stateStore: makeStateStore(),
                                   maxPagesPerCrawl: 10, readBudget: budget ?? makeBudget())
        return (client, .x(XSourceConfig(accountId: "u1", username: "@jack", stream: .bookmarks)))
    }

    func test_content_expands_thread_with_self_replies() async throws {
        let cleanup = seedToken(accountId: "u1"); defer { cleanup() }
        let log = RequestLog()
        StubURLProtocol.handler = { request, _ in
            log.record(request)
            if request.url!.path.hasSuffix("/search/recent") {
                return (200, self.envelope([
                    self.tweetJSON(id: "300", conversationId: "100", minute: 10),
                    self.tweetJSON(id: "200", conversationId: "100", minute: 5)
                ]))
            }
            return (200, self.envelope([self.tweetJSON(id: "100", conversationId: "100", minute: 0)]))
        }
        let (client, config) = makeExpansionClient()

        let items = try await client.listItems(config: config)
        let content = try await client.content(for: items[0], config: config)

        XCTAssertEqual(content.blocks, [
            .paragraph("tweet 100"), .paragraph("~~~"),
            .paragraph("tweet 200"), .paragraph("~~~"),
            .paragraph("tweet 300")
        ])
        XCTAssertEqual(log.lastSearchQuery, "conversation_id:100 from:u1 to:u1")
        XCTAssertEqual(log.lookupCount, 0, "anchor is the root; no root lookup needed")
    }

    func test_content_fetches_root_for_mid_thread_bookmark() async throws {
        let cleanup = seedToken(accountId: "u1"); defer { cleanup() }
        StubURLProtocol.handler = { request, _ in
            let path = request.url!.path
            if path.hasSuffix("/search/recent") {
                return (200, self.envelope([self.tweetJSON(id: "200", conversationId: "100", minute: 5)]))
            }
            if path.hasSuffix("/2/tweets") {
                return (200, self.envelope([self.tweetJSON(id: "100", conversationId: "100", minute: 0)]))
            }
            // The bookmarked anchor sits mid-thread (conversation root is 100).
            return (200, self.envelope([self.tweetJSON(id: "300", conversationId: "100", minute: 10)]))
        }
        let (client, config) = makeExpansionClient()

        let items = try await client.listItems(config: config)
        let content = try await client.content(for: items[0], config: config)

        XCTAssertEqual(content.blocks.first, .paragraph("tweet 100"), "thread starts at the fetched root")
        XCTAssertEqual(content.blocks, [
            .paragraph("tweet 100"), .paragraph("~~~"),
            .paragraph("tweet 200"), .paragraph("~~~"),
            .paragraph("tweet 300")
        ])
    }

    func test_root_by_another_author_is_dropped() async throws {
        let cleanup = seedToken(accountId: "u1"); defer { cleanup() }
        StubURLProtocol.handler = { request, _ in
            let path = request.url!.path
            if path.hasSuffix("/search/recent") {
                return (200, self.envelope([self.tweetJSON(id: "200", conversationId: "100", minute: 5)]))
            }
            if path.hasSuffix("/2/tweets") {
                // The conversation root belongs to someone else — not the thread.
                return (200, self.envelope([self.tweetJSON(id: "100", conversationId: "100", authorId: "u9", minute: 0)]))
            }
            return (200, self.envelope([self.tweetJSON(id: "300", conversationId: "100", minute: 10)]))
        }
        let (client, config) = makeExpansionClient()

        let items = try await client.listItems(config: config)
        let content = try await client.content(for: items[0], config: config)

        XCTAssertEqual(content.blocks, [
            .paragraph("tweet 200"), .paragraph("~~~"),
            .paragraph("tweet 300")
        ])
    }

    func test_expansion_reads_are_charged_to_the_budget() async throws {
        let cleanup = seedToken(accountId: "u1"); defer { cleanup() }
        StubURLProtocol.handler = { request, _ in
            let path = request.url!.path
            if path.hasSuffix("/search/recent") {
                return (200, self.envelope([self.tweetJSON(id: "200", conversationId: "100", minute: 5)]))
            }
            if path.hasSuffix("/2/tweets") {
                return (200, self.envelope([self.tweetJSON(id: "100", conversationId: "100", minute: 0)]))
            }
            return (200, self.envelope([self.tweetJSON(id: "300", conversationId: "100", minute: 10)]))
        }
        let budget = makeBudget()
        let (client, config) = makeExpansionClient(budget: budget)

        let items = try await client.listItems(config: config)
        _ = try await client.content(for: items[0], config: config)

        // 1 crawl read + 1 self-reply + 1 root lookup.
        XCTAssertEqual(budget.reads(now: Date()), 3)
    }

    func test_expansion_skipped_when_budget_exhausted() async throws {
        let cleanup = seedToken(accountId: "u1"); defer { cleanup() }
        let log = RequestLog()
        StubURLProtocol.handler = { request, _ in
            log.record(request)
            return (200, self.envelope([self.tweetJSON(id: "100", conversationId: "100", minute: 0)]))
        }
        let budget = makeBudget()
        let (client, config) = makeExpansionClient(budget: budget)

        let items = try await client.listItems(config: config)
        budget.record(reads: ReadBudget.monthlyCap, now: Date())   // spend the month
        let content = try await client.content(for: items[0], config: config)

        XCTAssertEqual(content.blocks, [.paragraph("tweet 100")], "root-only when there is no budget")
        XCTAssertEqual(log.searchCount, 0, "no search request is even attempted")
    }

    func test_search_403_disables_expansion_for_the_cycle() async throws {
        let cleanup = seedToken(accountId: "u1"); defer { cleanup() }
        let log = RequestLog()
        StubURLProtocol.handler = { request, _ in
            log.record(request)
            if request.url!.path.hasSuffix("/search/recent") { return (403, Data("{}".utf8)) }
            return (200, self.envelope([
                self.tweetJSON(id: "300", conversationId: "300", minute: 10),
                self.tweetJSON(id: "100", conversationId: "100", minute: 0)
            ]))
        }
        let (client, config) = makeExpansionClient()

        let items = try await client.listItems(config: config)
        let first = try await client.content(for: items[0], config: config)
        let second = try await client.content(for: items[1], config: config)

        XCTAssertEqual(first.blocks, [.paragraph("tweet 300")], "403 degrades to the anchor alone")
        XCTAssertEqual(second.blocks, [.paragraph("tweet 100")])
        XCTAssertEqual(log.searchCount, 1, "one 403 disables search for the rest of the cycle")
    }

    func test_expansion_failure_never_fails_the_item() async throws {
        let cleanup = seedToken(accountId: "u1"); defer { cleanup() }
        StubURLProtocol.handler = { request, _ in
            if request.url!.path.hasSuffix("/search/recent") { return (429, Data("{}".utf8)) }
            return (200, self.envelope([self.tweetJSON(id: "100", conversationId: "100", minute: 0)]))
        }
        let (client, config) = makeExpansionClient()

        let items = try await client.listItems(config: config)
        let content = try await client.content(for: items[0], config: config)

        XCTAssertEqual(content.blocks, [.paragraph("tweet 100")], "a rate-limited search still yields the anchor")
    }

    func test_conversation_expansion_is_memoized_per_cycle() async throws {
        let cleanup = seedToken(accountId: "u1"); defer { cleanup() }
        let log = RequestLog()
        StubURLProtocol.handler = { request, _ in
            log.record(request)
            if request.url!.path.hasSuffix("/search/recent") {
                return (200, self.envelope([
                    self.tweetJSON(id: "300", conversationId: "100", minute: 10),
                    self.tweetJSON(id: "200", conversationId: "100", minute: 5)
                ]))
            }
            // Two bookmarks from the same thread arrive in one crawl.
            return (200, self.envelope([
                self.tweetJSON(id: "300", conversationId: "100", minute: 10),
                self.tweetJSON(id: "100", conversationId: "100", minute: 0)
            ]))
        }
        let (client, config) = makeExpansionClient()

        let items = try await client.listItems(config: config)
        _ = try await client.content(for: items[0], config: config)
        _ = try await client.content(for: items[1], config: config)

        XCTAssertEqual(log.searchCount, 1, "the second item in the conversation reuses the cached expansion")
    }

    func test_posts_stream_never_expands() async throws {
        let cleanup = seedToken(accountId: "u1"); defer { cleanup() }
        let log = RequestLog()
        StubURLProtocol.handler = { request, _ in
            log.record(request)
            return (200, self.envelope([self.tweetJSON(id: "100", conversationId: "100", minute: 0)]))
        }
        let client = XSourceClient(keychain: .shared, session: makeSession(), stateStore: makeStateStore(),
                                   maxPagesPerCrawl: 10, readBudget: makeBudget())
        let config = SourceConfiguration.x(XSourceConfig(accountId: "u1", username: "@jack", stream: .posts))

        let items = try await client.listItems(config: config)
        let content = try await client.content(for: items[0], config: config)

        XCTAssertEqual(content.blocks, [.paragraph("tweet 100")])
        XCTAssertEqual(log.searchCount, 0, "own posts already sync every thread tweet as its own item")
    }

    func test_crawl_is_skipped_when_the_monthly_budget_is_spent() async throws {
        let cleanup = seedToken(accountId: "u1"); defer { cleanup() }
        let budget = makeBudget()
        budget.record(reads: ReadBudget.monthlyCap, now: Date())   // exhaust it
        StubURLProtocol.handler = { _, _ in (200, self.timelineJSON(ids: ["3", "2", "1"], nextToken: nil)) }
        let client = XSourceClient(keychain: .shared, session: makeSession(), stateStore: makeStateStore(),
                                   maxPagesPerCrawl: 10, readBudget: budget)
        let config = SourceConfiguration.x(XSourceConfig(accountId: "u1", username: "@jack", stream: .posts))

        let items = try await client.listItems(config: config)
        XCTAssertTrue(items.isEmpty, "no crawl runs when the monthly budget is spent")
        XCTAssertEqual(budget.reads(now: Date()), ReadBudget.monthlyCap, "no extra reads are charged")
    }
}
