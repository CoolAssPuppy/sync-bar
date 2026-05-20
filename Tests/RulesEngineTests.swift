//
//  RulesEngineTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

final class RulesEngineTests: XCTestCase {
    private let engine = RulesEngine()

    func test_unchanged_page_skips() {
        let rule = makeRule()
        let page = makePage(versionHash: "abc")
        let directive = engine.evaluate(rule: rule, page: page, ocrText: nil, previouslySyncedHash: "abc")
        XCTAssertEqual(directive, .skip(reason: .unchanged))
    }

    func test_disabled_rule_skips() {
        var rule = makeRule()
        rule.enabled = false
        let directive = engine.evaluate(rule: rule, page: makePage(), ocrText: "hi", previouslySyncedHash: nil)
        XCTAssertEqual(directive, .skip(reason: .ruleDisabled))
    }

    func test_page_number_title() {
        var rule = makeRule()
        rule.titleStrategy = .pageNumber
        let title = engine.resolveTitle(rule: rule, page: makePage(positionInNotebook: 4), ocrText: nil)
        XCTAssertEqual(title, "Page 5")
    }

    func test_first_line_falls_back_when_ocr_empty() {
        let rule = makeRule()
        let title = engine.resolveTitle(rule: rule, page: makePage(positionInNotebook: 2), ocrText: nil)
        XCTAssertEqual(title, "Quarterly · page 3")
    }

    func test_first_line_uses_ocr_when_present() {
        let rule = makeRule()
        let title = engine.resolveTitle(rule: rule, page: makePage(), ocrText: "Sprint planning\nMore notes")
        XCTAssertEqual(title, "Sprint planning")
    }

    // MARK: Helpers

    private func makeRule() -> SyncRule {
        SyncRule.new(notebookId: "nb-1", notebookName: "Quarterly")
    }

    private func makePage(versionHash: String = "v1", positionInNotebook: Int = 0) -> RmPage {
        RmPage(
            notebookId: "nb-1",
            pageId: "page-\(positionInNotebook)",
            positionInNotebook: positionInNotebook,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_001_000),
            hasTypedText: true,
            versionHash: versionHash
        )
    }
}
