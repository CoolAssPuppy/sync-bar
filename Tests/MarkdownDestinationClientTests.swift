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

    /// A "/" in the template makes subfolders: the source folder name becomes a
    /// directory and the intermediate folders are created on write. The slash is
    /// preserved (not sanitized away) while each path component is still cleaned.
    func test_template_with_slash_writes_into_subfolders() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("syncbar-md-subfolder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let client = MarkdownDestinationClient()
        let configuration = DestinationConfiguration.markdownFolder(
            MarkdownFolderDestinationConfig(
                folderPath: tempDir.path,
                fileNameTemplate: "{folder_name}/{date}-{title}",
                includeFrontmatter: false
            )
        )
        let payload = DestinationPayload(
            title: "Auth flow",
            body: "RLS notes.",
            sourceDate: Date(timeIntervalSince1970: 1_700_000_000),
            pdfData: nil,
            ocrProvider: nil,
            ruleNotebookName: "RLS",
            folderName: "Supabase",
            pageNumber: 1
        )

        let result = try await client.write(payload: payload, configuration: configuration, existingExternalId: nil)
        let written = try XCTUnwrap(result.externalURL)

        // Lands under <base>/Supabase/<date>-Auth flow.md
        XCTAssertEqual(written.deletingLastPathComponent().lastPathComponent, "Supabase")
        XCTAssertTrue(written.lastPathComponent.hasSuffix("-Auth flow.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
        XCTAssertTrue(try String(contentsOf: written).contains("# Auth flow"))
    }

    /// Illegal filename characters inside a component are replaced, but the path
    /// separator survives so the subfolder structure is intact.
    func test_subfolder_components_are_sanitized_but_slash_preserved() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("syncbar-md-sanitize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let client = MarkdownDestinationClient()
        let configuration = DestinationConfiguration.markdownFolder(
            MarkdownFolderDestinationConfig(
                folderPath: tempDir.path,
                fileNameTemplate: "{folder_name}/{title}",
                includeFrontmatter: false
            )
        )
        let payload = DestinationPayload(
            title: "Q3: plan?",
            body: "x",
            sourceDate: Date(timeIntervalSince1970: 1_700_000_000),
            pdfData: nil,
            ocrProvider: nil,
            ruleNotebookName: "Roadmap",
            folderName: "Work",
            pageNumber: 1
        )

        let result = try await client.write(payload: payload, configuration: configuration, existingExternalId: nil)
        let written = try XCTUnwrap(result.externalURL)

        XCTAssertEqual(written.deletingLastPathComponent().lastPathComponent, "Work")
        // ":" and "?" replaced with "-", slash kept as the folder boundary.
        XCTAssertEqual(written.lastPathComponent, "Q3- plan-.md")
    }

    /// A "/" inside a *token value* (a note titled "Jess/Prashant …") must not
    /// spawn a subfolder. Only a literal "/" in the template makes folders; the
    /// slash in the substituted title is sanitized into the file name.
    func test_slash_in_title_value_does_not_create_subfolder() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("syncbar-md-title-slash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let client = MarkdownDestinationClient()
        let configuration = DestinationConfiguration.markdownFolder(
            MarkdownFolderDestinationConfig(
                folderPath: tempDir.path,
                fileNameTemplate: "{date}-{title}",
                includeFrontmatter: false
            )
        )
        let payload = DestinationPayload(
            title: "Jess/Prashant Bi-Weekly 1-1",
            body: "x",
            sourceDate: Date(timeIntervalSince1970: 1_700_000_000),
            pdfData: nil,
            ocrProvider: nil,
            ruleNotebookName: "Supabase",
            pageNumber: 1
        )

        let result = try await client.write(payload: payload, configuration: configuration, existingExternalId: nil)
        let written = try XCTUnwrap(result.externalURL)

        // The file lands directly in the base folder, not inside a "…-Jess" dir.
        XCTAssertEqual(written.deletingLastPathComponent().path, tempDir.path)
        XCTAssertTrue(written.lastPathComponent.hasSuffix("-Jess-Prashant Bi-Weekly 1-1.md"))
    }
}
