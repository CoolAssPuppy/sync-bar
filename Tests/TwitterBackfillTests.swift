//
//  TwitterBackfillTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The one-shot maker backfill: adopting existing Notion rows by tweet URL so
//  a full bookmarks resync updates each row in place (filling the Notes
//  column) instead of duplicating it.
//

import XCTest
@testable import SyncBar

@MainActor
final class TwitterBackfillTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.handler = nil
        AppSettings.defaults.removeObject(forKey: TwitterBackfill.didRunDefaultsKey)
        super.tearDown()
    }

    // MARK: Tweet id extraction

    func test_tweetId_parses_status_permalinks() {
        XCTAssertEqual(TwitterBackfill.tweetId(fromStatusURL: "https://x.com/jack/status/20"), "20")
        XCTAssertEqual(TwitterBackfill.tweetId(fromStatusURL: "https://twitter.com/jack/status/20"), "20")
        XCTAssertEqual(TwitterBackfill.tweetId(fromStatusURL: "https://x.com/i/web/status/12345"), "12345")
        XCTAssertEqual(TwitterBackfill.tweetId(fromStatusURL: "https://x.com/jack/status/20?s=46"), "20")
    }

    func test_tweetId_rejects_non_tweet_urls() {
        XCTAssertNil(TwitterBackfill.tweetId(fromStatusURL: "https://example.com/jack/status/20"))
        XCTAssertNil(TwitterBackfill.tweetId(fromStatusURL: "https://x.com/jack"))
        XCTAssertNil(TwitterBackfill.tweetId(fromStatusURL: "https://x.com/jack/status/not-a-number"))
        XCTAssertNil(TwitterBackfill.tweetId(fromStatusURL: ""))
    }

    // MARK: Query-page parsing

    func test_parseQueryPage_extracts_page_ids_and_url_properties() throws {
        let json = #"""
        {
          "results": [
            {"id": "page-1", "properties": {
              "Site": {"type": "rich_text", "rich_text": [{"plain_text": "twitter.com"}]},
              "URL": {"type": "url", "url": "https://x.com/jack/status/111"}
            }},
            {"id": "page-2", "properties": {
              "URL": {"type": "url", "url": "https://readwise.io/article"}
            }},
            {"id": "page-3", "properties": {
              "URL": {"type": "url", "url": null}
            }}
          ],
          "has_more": true,
          "next_cursor": "CURSOR-2"
        }
        """#
        let page = try TwitterBackfill.parseQueryPage(Data(json.utf8))
        XCTAssertEqual(page.rows, [
            TwitterBackfill.AdoptableRow(pageId: "page-1", url: "https://x.com/jack/status/111"),
            TwitterBackfill.AdoptableRow(pageId: "page-2", url: "https://readwise.io/article")
        ], "rows keep their first url-typed property; null urls drop")
        XCTAssertEqual(page.nextCursor, "CURSOR-2")
    }

    func test_parseQueryPage_last_page_has_no_cursor() throws {
        let json = #"{"results": [], "has_more": false, "next_cursor": null}"#
        let page = try TwitterBackfill.parseQueryPage(Data(json.utf8))
        XCTAssertTrue(page.rows.isEmpty)
        XCTAssertNil(page.nextCursor)
    }

    // MARK: Ledger adoption semantics

    func test_adoptExternalId_links_page_without_marking_it_synced() {
        let ledger = Ledger.shared
        let binding = "backfill-binding-\(UUID().uuidString)"

        ledger.recordSyncedPage(bindingId: binding, pageId: "t1", versionHash: "t1", externalId: "old-page")
        ledger.adoptExternalId(bindingId: binding, pageId: "t1", externalId: "notion-page-1")

        XCTAssertEqual(ledger.syncedExternalId(bindingId: binding, pageId: "t1"), "notion-page-1",
                       "the next write must update the adopted page in place")
        XCTAssertNil(ledger.syncedHash(bindingId: binding, pageId: "t1"),
                     "no hash means the next cycle re-renders the item")
    }

    // MARK: Read budget reset

    func test_resetMonth_zeroes_the_current_tally() {
        let name = "backfill.budget.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let budget = ReadBudget(defaults: defaults, timeZone: .pacific)

        budget.record(reads: 500, now: Date())
        budget.resetMonth(now: Date())
        XCTAssertEqual(budget.reads(now: Date()), 0)
        XCTAssertEqual(budget.remaining(now: Date()), ReadBudget.monthlyCap)
    }

    // MARK: Full run (stubbed Notion)

    func test_run_adopts_rows_resets_state_and_marks_done() async throws {
        let ledger = Ledger.shared

        // A production-shaped Twitter rule with a Notion database binding.
        var rule = SyncRule(source: .x(XSourceConfig(accountId: "backfill-acct", username: "@u", stream: .bookmarks)))
        let notionConfig = NotionDestinationConfig(
            workspaceId: "ws-backfill", destinationId: "db-backfill",
            destinationType: .database, destinationTitle: "Read it Later",
            propertyMappings: ["Notes": .text(template: "{text}")])
        rule.destinations = [DestinationBinding(configuration: .notion(notionConfig))]
        ledger.upsertRule(rule)
        defer { ledger.deleteRule(id: rule.id) }
        let bindingId = rule.destinations[0].id

        let kc = KeychainStore.shared
        kc.set(value: "notion-token", for: .notionWorkspaceToken(workspaceId: "ws-backfill"))
        defer { kc.delete(key: .notionWorkspaceToken(workspaceId: "ws-backfill")) }

        // Two query pages: one tweet row + one non-tweet row, then a tweet row.
        StubURLProtocol.handler = { _, body in
            let cursor = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["start_cursor"] as? String
            if cursor == "C2" {
                return (200, Data(#"{"results":[{"id":"page-b","properties":{"URL":{"type":"url","url":"https://x.com/u/status/222"}}}],"has_more":false,"next_cursor":null}"#.utf8))
            }
            return (200, Data(#"{"results":[{"id":"page-a","properties":{"URL":{"type":"url","url":"https://x.com/u/status/111"}}},{"id":"page-x","properties":{"URL":{"type":"url","url":"https://example.com/a"}}}],"has_more":true,"next_cursor":"C2"}"#.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)

        let stateName = "backfill.state.\(UUID().uuidString)"
        let stateDefaults = UserDefaults(suiteName: stateName)!
        stateDefaults.removePersistentDomain(forName: stateName)
        let stateStore = XSyncStateStore(store: stateDefaults)
        stateStore.recordSuccess(accountId: "backfill-acct", stream: .bookmarks,
                                 newestId: "999", processedIds: ["999"])
        let budget = ReadBudget(defaults: stateDefaults, timeZone: .pacific)
        budget.record(reads: 500, now: Date())

        let adopted = try await TwitterBackfill.run(
            ruleId: rule.id, ledger: ledger, keychain: kc, stateStore: stateStore,
            readBudget: budget, session: session, coordinator: nil)

        XCTAssertEqual(adopted, 2, "both tweet rows adopt; the non-tweet row is ignored")
        XCTAssertEqual(ledger.syncedExternalId(bindingId: bindingId, pageId: "111"), "page-a")
        XCTAssertEqual(ledger.syncedExternalId(bindingId: bindingId, pageId: "222"), "page-b")
        XCTAssertNil(ledger.syncedHash(bindingId: bindingId, pageId: "111"))
        XCTAssertTrue(stateStore.state(accountId: "backfill-acct", stream: .bookmarks).isInitialSync,
                      "the cursor resets so every bookmark re-lists")
        XCTAssertEqual(budget.reads(now: Date()), 0, "the month's meter clears for the backfill")
        XCTAssertTrue(TwitterBackfill.hasRun, "the switch is one-shot")
    }
}
