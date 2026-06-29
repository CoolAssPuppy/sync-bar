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

    private func sampleTweet(id: String = "111", text: String = "Hello world\nmore detail") -> XContent {
        XContent(
            id: id, stream: .bookmarks, text: text,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
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
