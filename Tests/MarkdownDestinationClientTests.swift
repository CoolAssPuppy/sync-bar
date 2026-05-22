//
//  MarkdownDestinationClientTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

final class MarkdownDestinationClientTests: XCTestCase {

    func test_writes_one_file_per_payload_with_frontmatter_and_mermaid() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("syncbar-md-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let client = MarkdownDestinationClient()
        let configuration = DestinationConfiguration.markdownFolder(
            MarkdownFolderDestinationConfig(
                folderPath: tempDir.path,
                fileNameTemplate: "{notebook}-page-{page_n}",
                includeFrontmatter: true
            )
        )
        let payload = DestinationPayload(
            title: "Strategy",
            body: "Quarterly priorities, then a diagram below.",
            mermaidSource: "flowchart TD\nA --> B",
            sourceDate: Date(timeIntervalSince1970: 1_700_000_000),
            pdfData: nil,
            ocrProvider: "vision",
            ruleNotebookName: "Quarterly",
            pageNumber: 3
        )

        let result = try await client.write(payload: payload, configuration: configuration, existingExternalId: nil)
        let written = try XCTUnwrap(result.externalURL)
        let contents = try String(contentsOf: written)

        XCTAssertTrue(contents.contains("# Strategy"))
        XCTAssertTrue(contents.contains("```mermaid"))
        XCTAssertTrue(contents.contains("flowchart TD"))
        XCTAssertTrue(contents.contains("notebook: \"Quarterly\""))
        XCTAssertTrue(written.lastPathComponent == "Quarterly-page-3.md")
    }

    /// The flattened body is already markdown, so a checklist must land in the
    /// file verbatim (native task syntax that Markdown editors and Linear both
    /// render as real checkboxes).
    func test_writes_checklist_markdown_verbatim() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("syncbar-md-checklist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let client = MarkdownDestinationClient()
        let configuration = DestinationConfiguration.markdownFolder(
            MarkdownFolderDestinationConfig(
                folderPath: tempDir.path,
                fileNameTemplate: "{notebook}",
                includeFrontmatter: false
            )
        )
        let payload = DestinationPayload(
            title: "Groceries",
            body: "## Groceries\n\n- [ ] Milk\n- [x] Eggs\n- a plain bullet",
            sourceDate: Date(timeIntervalSince1970: 1_700_000_000),
            pdfData: nil,
            ocrProvider: nil,
            ruleNotebookName: "Groceries",
            pageNumber: 1
        )

        let result = try await client.write(payload: payload, configuration: configuration, existingExternalId: nil)
        let contents = try String(contentsOf: try XCTUnwrap(result.externalURL))

        XCTAssertTrue(contents.contains("## Groceries"))
        XCTAssertTrue(contents.contains("- [ ] Milk"))
        XCTAssertTrue(contents.contains("- [x] Eggs"))
        XCTAssertTrue(contents.contains("- a plain bullet"))
    }
}
