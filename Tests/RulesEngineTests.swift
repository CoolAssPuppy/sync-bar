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

    func test_unchanged_file_skips() {
        let rule = makeRule()
        let file = makeFile(versionHash: "abc")
        let directive = engine.evaluate(rule: rule, file: file, folderName: "Work", ocrText: "hi", previouslySyncedHash: "abc")
        XCTAssertEqual(directive, .skip(reason: .unchanged))
    }

    func test_disabled_rule_skips() {
        var rule = makeRule()
        rule.enabled = false
        let directive = engine.evaluate(rule: rule, file: makeFile(), folderName: "Work", ocrText: "hi", previouslySyncedHash: nil)
        XCTAssertEqual(directive, .skip(reason: .ruleDisabled))
    }

    func test_file_name_title() {
        var rule = makeRule()
        rule.titleStrategy = .fileName
        let title = engine.resolveTitle(rule: rule, file: makeFile(name: "Sprint plan"), folderName: "Work", ocrText: nil)
        XCTAssertEqual(title, "Sprint plan")
    }

    func test_first_line_uses_ocr_when_present() {
        var rule = makeRule()
        rule.titleStrategy = .firstLineOfOcr
        let title = engine.resolveTitle(rule: rule, file: makeFile(name: "Note"), folderName: "Work", ocrText: "Sprint planning\nMore notes")
        XCTAssertEqual(title, "Sprint planning")
    }

    func test_first_line_falls_back_to_file_name_when_ocr_empty() {
        var rule = makeRule()
        rule.titleStrategy = .firstLineOfOcr
        let title = engine.resolveTitle(rule: rule, file: makeFile(name: "Untitled note"), folderName: "Work", ocrText: nil)
        XCTAssertEqual(title, "Untitled note")
    }

    func test_template_resolves_folder_and_note() {
        var rule = makeRule()
        rule.titleStrategy = .template
        rule.titleTemplate = "{folder_name} / {notebook}"
        let title = engine.resolveTitle(rule: rule, file: makeFile(name: "Standup"), folderName: "Work", ocrText: nil)
        XCTAssertEqual(title, "Work / Standup")
    }

    // MARK: Helpers

    private func makeRule() -> SyncRule {
        SyncRule.new(notebookId: "folder-1", notebookName: "Work")
    }

    private func makeFile(name: String = "Note", versionHash: String = "v1") -> RmFile {
        RmFile(
            id: "file-1",
            name: name,
            folderId: "folder-1",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastModified: Date(timeIntervalSince1970: 1_700_001_000),
            pageCount: 2,
            versionHash: versionHash
        )
    }
}
