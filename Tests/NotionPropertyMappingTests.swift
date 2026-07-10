//
//  NotionPropertyMappingTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

/// Pins the JSON shape `NotionDestinationClient.propertyValue(for:payload:)`
/// emits per `NotionPropertyMapping` case. If the helper goes private later
/// these tests will need a small adjustment, but the shapes must stay stable
/// because Notion validates them server-side.
final class NotionPropertyMappingTests: XCTestCase {

    func test_codable_round_trip_for_every_mapping_case() throws {
        let cases: [NotionPropertyMapping] = [
            .leaveBlank,
            .text(template: "{notebook} – {page_n}"),
            .selectOption("In progress"),
            .multiSelectOptions(["Engineering", "Design"]),
            .dateSource(.pageCreated),
            .dateSource(.syncedAt),
            .checkbox(true),
            .checkbox(false),
            .number(42),
            .literal("https://example.com")
        ]
        for original in cases {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(NotionPropertyMapping.self, from: data)
            XCTAssertEqual(original, decoded, "Round-trip failed for \(original)")
        }
    }

    func test_config_persists_property_mappings_through_destination_configuration() throws {
        let config = NotionDestinationConfig(
            workspaceId: "ws-1",
            destinationId: "db-tasks",
            destinationType: .database,
            destinationTitle: "Tasks",
            propertyMappings: [
                "Status": .selectOption("In progress"),
                "Tags": .multiSelectOptions(["A", "B"]),
                "Due": .dateSource(.pageCreated)
            ]
        )
        let configuration = DestinationConfiguration.notion(config)
        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(DestinationConfiguration.self, from: data)
        guard case .notion(let parsed) = decoded else {
            XCTFail("Decoded configuration is not a Notion case")
            return
        }
        XCTAssertEqual(parsed.propertyMappings.count, 3)
        XCTAssertEqual(parsed.propertyMappings["Status"], .selectOption("In progress"))
        XCTAssertEqual(parsed.propertyMappings["Tags"], .multiSelectOptions(["A", "B"]))
        XCTAssertEqual(parsed.propertyMappings["Due"], .dateSource(.pageCreated))
    }

    // MARK: rich_text property shape

    private func makePayload(body: String = "") -> DestinationPayload {
        DestinationPayload(title: "T", body: body, sourceDate: .distantPast,
                           ruleNotebookName: "Note", pageNumber: 1)
    }

    private func richTextContents(_ value: [String: Any]?) -> [String] {
        let objects = value?["rich_text"] as? [[String: Any]] ?? []
        return objects.compactMap { ($0["text"] as? [String: Any])?["content"] as? String }
    }

    func test_rich_text_property_short_value_is_single_object() {
        let value = NotionDestinationClient.propertyValue(
            for: .literal("hello"), columnType: "rich_text", payload: makePayload())
        XCTAssertEqual(richTextContents(value), ["hello"])
    }

    func test_rich_text_property_chunks_long_values_at_2000_chars() {
        // A full thread easily exceeds Notion's 2000-char per-text-object cap;
        // the property must split like body blocks already do, losslessly.
        let long = String(repeating: "x", count: 4500)
        let value = NotionDestinationClient.propertyValue(
            for: .literal(long), columnType: "rich_text", payload: makePayload())
        let contents = richTextContents(value)
        XCTAssertEqual(contents.count, 3)
        XCTAssertTrue(contents.allSatisfy { $0.count <= 2000 })
        XCTAssertEqual(contents.joined(), long)
    }

    func test_text_template_on_rich_text_column_carries_the_payload_body() {
        // The {text} token routes the full synced body (tweet + thread) into a
        // user-mapped column, chunking past the per-object cap.
        let body = String(repeating: "y", count: 2500)
        let value = NotionDestinationClient.propertyValue(
            for: .text(template: "{text}"), columnType: "rich_text", payload: makePayload(body: body))
        let contents = richTextContents(value)
        XCTAssertEqual(contents.count, 2)
        XCTAssertEqual(contents.joined(), body)
    }
}
