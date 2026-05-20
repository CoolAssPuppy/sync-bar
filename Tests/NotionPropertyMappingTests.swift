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
}
