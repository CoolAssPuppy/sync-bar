//
//  RulesEngineTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

/// The engine is now source-agnostic: it only combines the generic signals
/// (enabled, unchanged, suppressed-as-empty). Title resolution and the
/// "is this content empty?" decision are source-specific and covered in
/// RemarkableSourceClientTests.
final class RulesEngineTests: XCTestCase {
    private let engine = RulesEngine()

    func test_unchanged_item_skips() {
        let directive = engine.evaluate(enabled: true, itemVersionHash: "abc",
                                        previouslySyncedHash: "abc", suppressedAsEmpty: false)
        XCTAssertEqual(directive, .skip(reason: .unchanged))
    }

    func test_disabled_rule_skips() {
        let directive = engine.evaluate(enabled: false, itemVersionHash: "abc",
                                        previouslySyncedHash: nil, suppressedAsEmpty: false)
        XCTAssertEqual(directive, .skip(reason: .ruleDisabled))
    }

    func test_suppressed_as_empty_skips() {
        let directive = engine.evaluate(enabled: true, itemVersionHash: "v1",
                                        previouslySyncedHash: nil, suppressedAsEmpty: true)
        XCTAssertEqual(directive, .skip(reason: .ocrSkippedAndEmpty))
    }

    func test_changed_item_proceeds() {
        let directive = engine.evaluate(enabled: true, itemVersionHash: "v2",
                                        previouslySyncedHash: "v1", suppressedAsEmpty: false)
        XCTAssertEqual(directive, .proceed)
    }

    func test_first_sync_proceeds() {
        let directive = engine.evaluate(enabled: true, itemVersionHash: "v1",
                                        previouslySyncedHash: nil, suppressedAsEmpty: false)
        XCTAssertEqual(directive, .proceed)
    }
}
