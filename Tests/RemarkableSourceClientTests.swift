//
//  RemarkableSourceClientTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

/// Behavior of the reMarkable source: scope/item listing, content production,
/// title resolution (ported from the old RulesEngine tests), and the
/// empty-suppression gate.
final class RemarkableSourceClientTests: XCTestCase {

    // MARK: Title resolution

    func test_title_uses_file_name() {
        let client = RemarkableSourceClient(remarkable: StubRemarkableClient())
        let title = client.resolveTitle(for: item(name: "Sprint plan"), content: NoteContent(blocks: []),
                                        config: config(strategy: .fileName), strategyOverride: nil)
        XCTAssertEqual(title, "Sprint plan")
    }

    func test_title_first_line_uses_content_when_present() {
        let client = RemarkableSourceClient(remarkable: StubRemarkableClient())
        let content = NoteContent(blocks: [.paragraph("Sprint planning"), .paragraph("More notes")])
        let title = client.resolveTitle(for: item(name: "Note"), content: content,
                                        config: config(strategy: .firstLineOfOcr), strategyOverride: nil)
        XCTAssertEqual(title, "Sprint planning")
    }

    func test_title_first_line_falls_back_to_name_when_content_empty() {
        let client = RemarkableSourceClient(remarkable: StubRemarkableClient())
        let title = client.resolveTitle(for: item(name: "Untitled note"), content: NoteContent(blocks: []),
                                        config: config(strategy: .firstLineOfOcr), strategyOverride: nil)
        XCTAssertEqual(title, "Untitled note")
    }

    func test_title_template_resolves_folder_and_note() {
        let client = RemarkableSourceClient(remarkable: StubRemarkableClient())
        let title = client.resolveTitle(for: item(name: "Standup"), content: NoteContent(blocks: []),
                                        config: config(strategy: .template,
                                                       template: "{folder_name} / {notebook}",
                                                       folderName: "Work"),
                                        strategyOverride: nil)
        XCTAssertEqual(title, "Work / Standup")
    }

    func test_title_strategy_override_wins_over_config() {
        let client = RemarkableSourceClient(remarkable: StubRemarkableClient())
        let content = NoteContent(blocks: [.paragraph("OCR first line")])
        let title = client.resolveTitle(for: item(name: "Standup"), content: content,
                                        config: config(strategy: .fileName), strategyOverride: .firstLineOfOcr)
        XCTAssertEqual(title, "OCR first line")
    }

    // MARK: Empty suppression

    func test_suppresses_only_when_ocr_none_and_blank() {
        let client = RemarkableSourceClient(remarkable: StubRemarkableClient())
        XCTAssertTrue(client.shouldSkipAsEmpty(content: NoteContent(blocks: []),
                                               config: config(ocrMode: .none), ocrModeOverride: nil))
        XCTAssertFalse(client.shouldSkipAsEmpty(content: NoteContent(blocks: []),
                                                config: config(ocrMode: .all), ocrModeOverride: nil))
        XCTAssertFalse(client.shouldSkipAsEmpty(content: NoteContent(blocks: [.paragraph("hi")]),
                                                config: config(ocrMode: .none), ocrModeOverride: nil))
    }

    func test_suppression_honors_binding_override() {
        let client = RemarkableSourceClient(remarkable: StubRemarkableClient())
        // Rule says OCR all, but the binding overrides to none → a blank page suppresses.
        // (Spell out OcrMode.none: against an OcrMode? parameter a bare `.none`
        // would bind to Optional.none/nil, not the OCR mode.)
        XCTAssertTrue(client.shouldSkipAsEmpty(content: NoteContent(blocks: []),
                                               config: config(ocrMode: .all), ocrModeOverride: OcrMode.none))
    }

    // MARK: Scope + item listing

    func test_list_scopes_maps_folders() async throws {
        let client = RemarkableSourceClient(remarkable: StubRemarkableClient(folders: [
            RmFolder(id: "f1", name: "Work", parentFolder: nil, lastModified: Date(), pageCount: 2)
        ]))
        let scopes = try await client.listScopes()
        XCTAssertEqual(scopes, [SourceScope(id: "f1", name: "Work", itemCount: 2)])
    }

    func test_list_items_maps_files_in_folder() async throws {
        let client = RemarkableSourceClient(remarkable: StubRemarkableClient(files: [
            RmFile(id: "doc1", name: "Note", folderId: "f1", createdAt: Date(),
                   lastModified: Date(), pageCount: 1, versionHash: "h1", tags: ["x"])
        ]))
        let items = try await client.listItems(config: config(folderId: "f1"))
        XCTAssertEqual(items.map(\.id), ["doc1"])
        XCTAssertEqual(items.first?.versionHash, "h1")
        XCTAssertEqual(items.first?.tags, ["x"])
    }

    func test_content_renders_typed_text_into_blocks() async throws {
        let typed: [TypedParagraph] = [
            TypedParagraph(style: .heading, text: "Groceries"),
            TypedParagraph(style: .checkbox, text: "Milk")
        ]
        let client = RemarkableSourceClient(remarkable: StubRemarkableClient(typedText: typed))
        let content = try await client.content(for: item(name: "Note"), config: config())
        XCTAssertTrue(content.blocks.contains(.heading("Groceries")))
        XCTAssertTrue(content.blocks.contains(.checkbox(text: "Milk", checked: false)))
    }

    // MARK: Helpers

    private func item(id: String = "doc1", name: String) -> SourceItem {
        SourceItem(id: id, name: name, versionHash: "v1",
                   createdAt: Date(timeIntervalSince1970: 1_700_000_000), tags: [])
    }

    private func config(strategy: TitleStrategy = .fileName, template: String? = nil,
                        folderName: String = "Work", folderId: String = "f1",
                        ocrMode: OcrMode = .all) -> SourceConfiguration {
        .remarkable(RemarkableSourceConfig(
            folderId: folderId, folderName: folderName, selectedFileIds: nil,
            titleStrategy: strategy, titleTemplate: template, pageOrder: .chronological,
            ocrMode: ocrMode, ocrProviderOverride: .vision, savePdfAttachment: true))
    }
}

/// Configurable reMarkable client double for source-client tests.
private struct StubRemarkableClient: RemarkableClient {
    var folders: [RmFolder] = []
    var files: [RmFile] = []
    var typedText: [TypedParagraph] = []

    func pairDevice(oneTimeCode: String) async throws -> RemarkableAccount {
        RemarkableAccount(pairedAt: Date(), userIdentifier: "t", lastSyncedAt: nil)
    }
    func listFolders() async throws -> [RmFolder] { folders }
    func listFiles(inFolderId folderId: String) async throws -> [RmFile] { files }
    func listTags() async throws -> [String] { [] }
    func listPages(notebookId: String) async throws -> [RmPage] {
        [RmPage(notebookId: notebookId, pageId: "p0", positionInNotebook: 0,
                createdAt: Date(), modifiedAt: Date(), hasTypedText: true, versionHash: "ph")]
    }
    func pageContent(for page: RmPage) async throws -> RemarkablePageContent {
        RemarkablePageContent(imageData: nil, typedText: typedText)
    }
    func uploadDocument(fileURL: URL, toFolderId folderId: String,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> RmUploadResult {
        RmUploadResult(documentId: "u", visibleName: "u")
    }
}
