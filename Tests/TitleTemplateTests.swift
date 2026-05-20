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

    func test_inline_hint_lists_every_token() {
        let hint = TitleTemplateHelp.inlineHint
        for token in TitleToken.allCases {
            XCTAssertTrue(hint.contains(token.placeholder), "Hint missing \(token.placeholder)")
        }
    }
}
