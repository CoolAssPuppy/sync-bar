//
//  TitleTemplateTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

final class TitleTemplateTests: XCTestCase {

    func test_all_tokens_substitute() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let context = TitleTemplateContext(notebook: "Q2", pageNumber: 3, date: date, title: "Plan")
        let resolved = context.apply(to: "{notebook}-{date}-page-{page_n}-{title}")
        XCTAssertEqual(resolved, "Q2-2023-11-14-page-3-Plan")
    }

    func test_unknown_tokens_pass_through_untouched() {
        let context = TitleTemplateContext(notebook: "Q2", pageNumber: 1, date: Date(), title: "")
        let resolved = context.apply(to: "{notebook}-{garbage}")
        XCTAssertEqual(resolved, "Q2-{garbage}")
    }

    func test_source_metadata_tokens_resolve_from_metadata() {
        let context = TitleTemplateContext(
            notebook: "Hello world", pageNumber: 1, date: Date(), title: "Hello world",
            metadata: [
                "author": "@jack",
                "author_name": "Jack",
                "canonical_url": "https://x.com/jack/status/20",
                "id": "20",
                "stream": "bookmarks"
            ])
        XCTAssertEqual(context.apply(to: "{author}"), "@jack")
        XCTAssertEqual(context.apply(to: "{author_name}"), "Jack")
        XCTAssertEqual(context.apply(to: "{tweet_url}"), "https://x.com/jack/status/20")
        XCTAssertEqual(context.apply(to: "{tweet_id}"), "20")
        XCTAssertEqual(context.apply(to: "{stream}"), "bookmarks")
    }

    func test_source_metadata_tokens_are_empty_without_metadata() {
        let context = TitleTemplateContext(notebook: "n", pageNumber: 1, date: Date(), title: "t")
        XCTAssertEqual(context.apply(to: "x{author}{tweet_url}y"), "xy")
    }

    func test_inline_hint_lists_every_general_token() {
        let hint = TitleTemplateHelp.inlineHint
        for token in TitleToken.allCases where !token.isSourceSpecific {
            XCTAssertTrue(hint.contains(token.placeholder), "Hint missing \(token.placeholder)")
        }
    }

    func test_inline_hint_omits_source_specific_tokens() {
        // Twitter-only tokens (e.g. {author}, {tweet_url}) shouldn't clutter the
        // generic title/file-name hint, where they never resolve to anything.
        let hint = TitleTemplateHelp.inlineHint
        for token in TitleToken.allCases where token.isSourceSpecific {
            XCTAssertFalse(hint.contains(token.placeholder), "Hint should omit \(token.placeholder)")
        }
    }
}
