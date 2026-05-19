//
//  OCRPromptsTests.swift
//  SyncNerdsTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncNerds

final class OCRPromptsTests: XCTestCase {

    func test_extracts_mermaid_when_present() {
        let raw = "Some intro.\n\n<mermaid>\nflowchart TD\nA --> B\n</mermaid>\n"
        let result = OCRPrompts.extractMermaid(from: raw)
        XCTAssertEqual(result.text, "Some intro.")
        XCTAssertEqual(result.mermaidSource, "flowchart TD\nA --> B")
    }

    func test_no_mermaid_returns_trimmed_text() {
        let raw = "\nJust some prose.\n"
        let result = OCRPrompts.extractMermaid(from: raw)
        XCTAssertEqual(result.text, "Just some prose.")
        XCTAssertNil(result.mermaidSource)
    }

    func test_empty_mermaid_block_is_treated_as_no_diagram() {
        let raw = "Prose only.\n<mermaid>\n</mermaid>"
        let result = OCRPrompts.extractMermaid(from: raw)
        XCTAssertEqual(result.text, "Prose only.")
        XCTAssertNil(result.mermaidSource)
    }

    func test_prompt_instructs_model_to_use_sentinels() {
        XCTAssertTrue(OCRPrompts.systemPrompt.contains(OCRPrompts.mermaidOpen))
        XCTAssertTrue(OCRPrompts.systemPrompt.contains(OCRPrompts.mermaidClose))
    }
}
