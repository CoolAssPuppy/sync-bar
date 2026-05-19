//
//  MarkdownDestinationClientTests.swift
//  SyncNerdsTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncNerds

final class MarkdownDestinationClientTests: XCTestCase {

    func test_writes_one_file_per_payload_with_frontmatter_and_mermaid() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("syncnerds-md-tests-\(UUID().uuidString)", isDirectory: true)
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

        let result = try await client.write(payload: payload, configuration: configuration)
        let written = try XCTUnwrap(result.externalURL)
        let contents = try String(contentsOf: written)

        XCTAssertTrue(contents.contains("# Strategy"))
        XCTAssertTrue(contents.contains("```mermaid"))
        XCTAssertTrue(contents.contains("flowchart TD"))
        XCTAssertTrue(contents.contains("notebook: \"Quarterly\""))
        XCTAssertTrue(written.lastPathComponent == "Quarterly-page-3.md")
    }
}
