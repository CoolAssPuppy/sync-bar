//
//  NotionMarkdownTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

final class NotionMarkdownTests: XCTestCase {

    // MARK: Property serialization

    func testSerializesCommonPropertyTypes() {
        let props: [String: Any] = [
            "Title": ["type": "title", "title": [["plain_text": "Codes & Cards"]]],
            "Category": ["type": "multi_select", "multi_select": [["name": "Personal"], ["name": "Backup"]]],
            "Status": ["type": "status", "status": ["name": "Done"]],
            "Author": ["type": "rich_text", "rich_text": [["plain_text": "Prashant"]]],
            "Created Date": ["type": "date", "date": ["start": "2019-09-20"]],
            "Reviewed": ["type": "checkbox", "checkbox": true],
            "Empty": ["type": "select", "select": NSNull()]
        ]
        let out = NotionPageReader.serializeProperties(props)
        XCTAssertEqual(out["Title"], "Codes & Cards")
        XCTAssertEqual(out["Category"], "Personal, Backup")
        XCTAssertEqual(out["Status"], "Done")
        XCTAssertEqual(out["Author"], "Prashant")
        XCTAssertEqual(out["Created Date"], "2019-09-20")
        XCTAssertEqual(out["Reviewed"], "true")
        XCTAssertNil(out["Empty"], "blank values are omitted")
    }

    // MARK: Date column drives the note date

    func testDatePropertyOverridesCreatedTime() throws {
        let row: [String: Any] = [
            "id": "p1",
            "created_time": "2025-08-20T00:00:00.000Z",   // migration date
            "last_edited_time": "2026-05-19T00:00:00.000Z",
            "properties": [
                "Title": ["type": "title", "title": [["plain_text": "Codes & Cards"]]],
                "Created Date": ["type": "date", "date": ["start": "2019-09-20"]]   // original date
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: ["results": [row], "has_more": false])
        let (pages, _) = try NotionPageReader.parsePageSummaries(
            data: data, titleProperty: "Title", categoryProperty: "Category", dateProperty: "Created Date")
        let year = Calendar.current.component(.year, from: try XCTUnwrap(pages.first).createdAt)
        XCTAssertEqual(year, 2019, "the configured date column should win over created_time")
    }

    func testFallsBackToCreatedTimeWhenDatePropertyBlank() throws {
        let row: [String: Any] = [
            "id": "p2", "created_time": "2025-08-20T00:00:00.000Z", "last_edited_time": "2025-08-20T00:00:00.000Z",
            "properties": ["Title": ["type": "title", "title": [["plain_text": "X"]]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: ["results": [row], "has_more": false])
        let (pages, _) = try NotionPageReader.parsePageSummaries(
            data: data, titleProperty: "Title", categoryProperty: "Category", dateProperty: "Created Date")
        XCTAssertEqual(Calendar.current.component(.year, from: try XCTUnwrap(pages.first).createdAt), 2025)
    }

    // MARK: Markdown adoption index

    func testParsesNotionIdFromFrontmatter() {
        let fm = """
        ---
        title: Codes & Cards
        notion_id: 255a555c-5905-8155-af1a-e8ef5e4728af
        category: Personal
        ---

        body
        """
        XCTAssertEqual(MarkdownAdoptionIndex.parseNotionId(frontmatter: fm), "255a555c-5905-8155-af1a-e8ef5e4728af")
    }

    func testNoNotionIdWhenNoFrontmatter() {
        XCTAssertNil(MarkdownAdoptionIndex.parseNotionId(frontmatter: "# Just a heading\n\nbody"))
    }

    func testStopsAtClosingDelimiter() {
        // A `notion_id:` in the body (after the closing ---) must not be read.
        let fm = "---\ntitle: X\n---\nnotion_id: not-real\n"
        XCTAssertNil(MarkdownAdoptionIndex.parseNotionId(frontmatter: fm))
    }

    // MARK: Frontmatter modes

    private func notionPayload() -> DestinationPayload {
        DestinationPayload(
            title: "Codes & Cards", body: "x", mermaidSource: nil, sourceDate: Date(timeIntervalSince1970: 0),
            ruleNotebookName: "Codes & Cards", pageNumber: 1, folderPath: ["Personal"],
            sourceId: "255a-id", metadata: ["last_edited": "2026-05-19T00:00:00Z", "Author": "Prashant", "Status": "Done"])
    }

    func testEssentialFrontmatterHasIdentityFields() {
        let fm = MarkdownDestinationClient.frontmatter(payload: notionPayload(), mode: .essential)
        XCTAssertTrue(fm.contains("notion_id: 255a-id"))
        XCTAssertTrue(fm.contains("category: \"Personal\""))
        XCTAssertTrue(fm.contains("last_edited: 2026-05-19T00:00:00Z"))
        XCTAssertFalse(fm.contains("Author"), "essential mode omits arbitrary columns")
    }

    func testAllFrontmatterIncludesEveryColumn() {
        let fm = MarkdownDestinationClient.frontmatter(payload: notionPayload(), mode: .all)
        XCTAssertTrue(fm.contains("Author: \"Prashant\""))
        XCTAssertTrue(fm.contains("Status: \"Done\""))
        XCTAssertFalse(fm.contains("last_edited: \"2026"), "last_edited is emitted once, not re-dumped as a column")
    }

    func testNoneFrontmatterIsEmpty() {
        XCTAssertEqual(MarkdownDestinationClient.frontmatter(payload: notionPayload(), mode: .none), "")
    }

    // MARK: Category routing

    func testCategoryBecomesLeadingSubfolder() {
        let path = MarkdownDestinationClient.resolveRelativePath(template: "{date}-{title}", payload: notionPayload())
        XCTAssertEqual(path, "Personal/1970-01-01-Codes & Cards.md")
    }

    func testNoCategoryKeepsTemplateOnly() {
        var payload = notionPayload(); payload.folderPath = []
        let path = MarkdownDestinationClient.resolveRelativePath(template: "{title}", payload: payload)
        XCTAssertEqual(path, "Codes & Cards.md")
    }
}
