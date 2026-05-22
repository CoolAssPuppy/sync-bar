//
//  MarkdownTargetTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

/// A Markdown destination carries the default configuration each connection
/// inherits, so a new connection never starts with a blank folder.
final class MarkdownTargetTests: XCTestCase {

    func test_default_configuration_uses_the_targets_chosen_settings() {
        let target = MarkdownTarget(
            id: "md-1", displayName: "Vault", folderPath: "/Users/me/Obsidian/Journal",
            connectedAt: Date(), fileNameTemplate: "{date}-{title}", includeFrontmatter: false
        )
        let config = target.defaultConfiguration
        XCTAssertEqual(config.folderPath, "/Users/me/Obsidian/Journal")
        XCTAssertEqual(config.fileNameTemplate, "{date}-{title}")
        XCTAssertFalse(config.includeFrontmatter)
    }

    func test_default_configuration_falls_back_to_standard_defaults() {
        let target = MarkdownTarget(
            id: "md-2", displayName: "Vault", folderPath: "/tmp/vault", connectedAt: Date()
        )
        let config = target.defaultConfiguration
        XCTAssertEqual(config.fileNameTemplate, MarkdownTarget.defaultFileNameTemplate)
        XCTAssertTrue(config.includeFrontmatter)
        XCTAssertEqual(config.folderPath, "/tmp/vault")
    }

    /// A target persisted before the template/frontmatter fields existed must
    /// still decode (the keys are simply absent) and yield sensible defaults.
    func test_target_persisted_without_new_fields_still_decodes() throws {
        let legacyJSON = Data("""
        {"id":"md-3","displayName":"Vault","folderPath":"/tmp/legacy","connectedAt":0}
        """.utf8)
        let target = try JSONDecoder().decode(MarkdownTarget.self, from: legacyJSON)

        XCTAssertNil(target.fileNameTemplate)
        XCTAssertNil(target.includeFrontmatter)
        XCTAssertEqual(target.defaultConfiguration.fileNameTemplate, MarkdownTarget.defaultFileNameTemplate)
        XCTAssertTrue(target.defaultConfiguration.includeFrontmatter)
        XCTAssertEqual(target.defaultConfiguration.folderPath, "/tmp/legacy")
    }
}
