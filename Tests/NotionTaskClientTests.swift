//
//  NotionTaskClientTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Step 2: Notion task-row projection (read) and property encoding (write),
//  plus pagination and the archive/create network shapes via StubURLProtocol.
//

import XCTest
@testable import SyncBar

final class NotionTaskClientTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func statusMapping() -> TaskFieldMapping {
        TaskFieldMapping(titleProperty: "Name",
                         dueDateProperty: "Due",
                         statusProperty: "Status",
                         statusPropertyType: "status",
                         statusDoneValue: "Done",
                         statusNotDoneValue: "To-do",
                         notesProperty: "Notes")
    }

    // MARK: Read projection

    func test_canonical_task_projects_all_mapped_fields() {
        let props: [String: Any] = [
            "Name":   ["title": [["plain_text": "Email Bob"]]],
            "Due":    ["date": ["start": "2026-06-05"]],
            "Status": ["status": ["name": "Done"]],
            "Notes":  ["rich_text": [["plain_text": "two "], ["plain_text": "runs"]]]
        ]
        let task = RealNotionTaskClient.canonicalTask(fromProperties: props, mapping: statusMapping())
        XCTAssertEqual(task.title, "Email Bob")
        XCTAssertEqual(task.notes, "two runs")
        XCTAssertTrue(task.isCompleted)
        XCTAssertNotNil(task.due)
    }

    func test_completion_reads_checkbox_and_is_case_insensitive_for_status() {
        let checkboxMapping = TaskFieldMapping(titleProperty: "Name", statusProperty: "Done?",
                                               statusPropertyType: "checkbox")
        let checked = RealNotionTaskClient.canonicalTask(
            fromProperties: ["Name": ["title": [["plain_text": "T"]]], "Done?": ["checkbox": true]],
            mapping: checkboxMapping)
        XCTAssertTrue(checked.isCompleted)

        // Status option compares case-insensitively to the configured done value.
        let lowercased = RealNotionTaskClient.canonicalTask(
            fromProperties: ["Name": ["title": [["plain_text": "T"]]], "Status": ["status": ["name": "done"]]],
            mapping: statusMapping())
        XCTAssertTrue(lowercased.isCompleted)

        let notDone = RealNotionTaskClient.canonicalTask(
            fromProperties: ["Name": ["title": [["plain_text": "T"]]], "Status": ["status": ["name": "To-do"]]],
            mapping: statusMapping())
        XCTAssertFalse(notDone.isCompleted)
    }

    func test_missing_columns_project_to_empty_and_nil() {
        let task = RealNotionTaskClient.canonicalTask(
            fromProperties: ["Name": ["title": [["plain_text": "Only a title"]]]],
            mapping: statusMapping())
        XCTAssertEqual(task.title, "Only a title")
        XCTAssertNil(task.due)
        XCTAssertNil(task.notes)
        XCTAssertFalse(task.isCompleted)
    }

    // MARK: Date parsing

    func test_parse_date_handles_date_only_and_iso_timestamp() {
        XCTAssertNotNil(RealNotionTaskClient.parseDate("2026-06-05"))
        XCTAssertNotNil(RealNotionTaskClient.parseDate("2026-06-05T09:30:00.000-07:00"))
        XCTAssertNotNil(RealNotionTaskClient.parseDate("2026-06-05T16:30:00Z"))
        XCTAssertNil(RealNotionTaskClient.parseDate(""))
        XCTAssertNil(RealNotionTaskClient.parseDate(42))
    }

    // MARK: Write encoding

    func test_properties_encode_title_due_status_and_notes() {
        // Build the due date in the machine calendar at noon so the encoder's
        // .current-calendar day-string can't cross a midnight boundary.
        let due = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 5, hour: 12))!
        let expectedDay = RealNotionTaskClient.dayString(due)
        let task = CanonicalTask(title: "Ship", due: due, isCompleted: true, notes: "ship it")

        let props = RealNotionTaskClient.properties(for: task, mapping: statusMapping())

        let title = ((props["Name"] as? [String: Any])?["title"] as? [[String: Any]])?.first
        XCTAssertEqual((title?["text"] as? [String: Any])?["content"] as? String, "Ship")
        XCTAssertEqual(expectedDay, "2026-06-05")
        XCTAssertEqual(((props["Due"] as? [String: Any])?["date"] as? [String: Any])?["start"] as? String, expectedDay)
        XCTAssertEqual(((props["Status"] as? [String: Any])?["status"] as? [String: Any])?["name"] as? String, "Done")
        let notes = ((props["Notes"] as? [String: Any])?["rich_text"] as? [[String: Any]])?.first
        XCTAssertEqual((notes?["text"] as? [String: Any])?["content"] as? String, "ship it")
    }

    func test_nil_due_and_empty_notes_clear_the_columns() {
        let task = CanonicalTask(title: "T", due: nil, isCompleted: false, notes: nil)
        let props = RealNotionTaskClient.properties(for: task, mapping: statusMapping())
        // A nil due clears the Notion date with an explicit null.
        XCTAssertTrue((props["Due"] as? [String: Any])?["date"] is NSNull)
        // Empty notes clears the rich_text with an empty array.
        XCTAssertEqual(((props["Notes"] as? [String: Any])?["rich_text"] as? [[String: Any]])?.count, 0)
        // Incomplete with a configured not-done option writes that option.
        XCTAssertEqual(((props["Status"] as? [String: Any])?["status"] as? [String: Any])?["name"] as? String, "To-do")
    }

    func test_incomplete_without_not_done_value_leaves_status_untouched() {
        let mapping = TaskFieldMapping(titleProperty: "Name", statusProperty: "Status",
                                       statusPropertyType: "status", statusDoneValue: "Done")
        let props = RealNotionTaskClient.properties(for: CanonicalTask(title: "T", isCompleted: false), mapping: mapping)
        XCTAssertNil(props["Status"], "no not-done option configured → status column is left as-is")
    }

    func test_priority_encodes_only_when_present_and_reads_known_buckets() {
        let mapping = TaskFieldMapping(titleProperty: "Name", priorityProperty: "Priority", priorityPropertyType: "select")

        let withPriority = RealNotionTaskClient.properties(for: CanonicalTask(title: "T", priority: "High"), mapping: mapping)
        XCTAssertEqual(((withPriority["Priority"] as? [String: Any])?["select"] as? [String: Any])?["name"] as? String, "High")

        // nil priority omits the column entirely (so a non-standard Notion priority is never wiped).
        let without = RealNotionTaskClient.properties(for: CanonicalTask(title: "T"), mapping: mapping)
        XCTAssertNil(without["Priority"])

        let low = RealNotionTaskClient.canonicalTask(
            fromProperties: ["Name": ["title": [["plain_text": "T"]]], "Priority": ["select": ["name": "Low"]]],
            mapping: mapping)
        XCTAssertEqual(low.priority, "Low")

        // An option that isn't recognizably high/medium/low is left unmapped.
        let custom = RealNotionTaskClient.canonicalTask(
            fromProperties: ["Name": ["title": [["plain_text": "T"]]], "Priority": ["select": ["name": "P1"]]],
            mapping: mapping)
        XCTAssertNil(custom.priority)
    }

    func test_checkbox_status_encodes_bool() {
        let mapping = TaskFieldMapping(titleProperty: "Name", statusProperty: "Done?", statusPropertyType: "checkbox")
        let done = RealNotionTaskClient.properties(for: CanonicalTask(title: "T", isCompleted: true), mapping: mapping)
        XCTAssertEqual((done["Done?"] as? [String: Any])?["checkbox"] as? Bool, true)
    }

    // MARK: Pagination (parse-level)

    func test_parse_query_response_extracts_next_cursor_only_when_has_more() throws {
        let withMore: [String: Any] = ["results": [], "has_more": true, "next_cursor": "cur-2"]
        let (_, next1) = try RealNotionTaskClient.parseQueryResponse(
            data: try JSONSerialization.data(withJSONObject: withMore), mapping: statusMapping())
        XCTAssertEqual(next1, "cur-2")

        let done: [String: Any] = ["results": [], "has_more": false, "next_cursor": "ignored"]
        let (_, next2) = try RealNotionTaskClient.parseQueryResponse(
            data: try JSONSerialization.data(withJSONObject: done), mapping: statusMapping())
        XCTAssertNil(next2)
    }

    // MARK: Network shapes

    func test_query_database_follows_pagination_across_pages() async throws {
        let mapping = statusMapping()
        func row(_ id: String, _ title: String) -> [String: Any] {
            ["id": id, "archived": false, "last_edited_time": "2026-06-05T10:00:00.000Z",
             "properties": ["Name": ["title": [["plain_text": title]]]]]
        }
        StubURLProtocol.handler = { _, body in
            let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let cursor = parsed?["start_cursor"] as? String
            let page: [String: Any] = cursor == nil
                ? ["results": [row("a", "First")], "has_more": true, "next_cursor": "cur-2"]
                : ["results": [row("b", "Second")], "has_more": false]
            return (200, try! JSONSerialization.data(withJSONObject: page))
        }

        let client = RealNotionTaskClient(token: "t", session: makeSession())
        let rows = try await client.queryDatabase(databaseId: "db", mapping: mapping)
        XCTAssertEqual(rows.map(\.pageId), ["a", "b"])
        XCTAssertEqual(rows.map(\.task.title), ["First", "Second"])
    }

    func test_archive_page_sends_patch_with_archived_true() async throws {
        let box = BodyBox()
        StubURLProtocol.handler = { request, body in
            box.method = request.httpMethod
            box.body = body
            return (200, Data("{}".utf8))
        }
        let client = RealNotionTaskClient(token: "t", session: makeSession())
        try await client.archivePage(pageId: "page-1")

        XCTAssertEqual(box.method, "PATCH")
        let parsed = (try? JSONSerialization.jsonObject(with: box.body ?? Data())) as? [String: Any]
        XCTAssertEqual(parsed?["archived"] as? Bool, true)
    }

    func test_create_page_posts_database_parent_and_returns_id() async throws {
        let box = BodyBox()
        StubURLProtocol.handler = { request, body in
            box.method = request.httpMethod
            box.body = body
            return (200, Data(#"{"id":"new-page"}"#.utf8))
        }
        let client = RealNotionTaskClient(token: "t", session: makeSession())
        let id = try await client.createPage(databaseId: "db-7",
                                             task: CanonicalTask(title: "New"),
                                             mapping: statusMapping())
        XCTAssertEqual(id, "new-page")
        XCTAssertEqual(box.method, "POST")
        let parsed = (try? JSONSerialization.jsonObject(with: box.body ?? Data())) as? [String: Any]
        XCTAssertEqual((parsed?["parent"] as? [String: Any])?["database_id"] as? String, "db-7")
    }
}

/// Captures the last request method + body for network-shape assertions.
private final class BodyBox: @unchecked Sendable {
    var method: String?
    var body: Data?
}
