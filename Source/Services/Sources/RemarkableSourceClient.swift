//
//  RemarkableSourceClient.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// The first `SourceClient`: reMarkable. Wraps the low-level `RemarkableClient`
/// (cloud API) and owns the read + transcription logic that used to live inline
/// in `SyncCoordinator.buildNoteContent` and `RulesEngine.resolveTitle`. OCR runs
/// here, once per item, and the result is reused across every destination.
struct RemarkableSourceClient: SourceClient {
    let kind: SourceKind = .remarkable

    private let remarkable: RemarkableClient

    init(remarkable: RemarkableClient = RemarkableClientFactory.make()) {
        self.remarkable = remarkable
    }

    func listScopes() async throws -> [SourceScope] {
        try await remarkable.listFolders().map {
            SourceScope(id: $0.id, name: $0.name, itemCount: $0.pageCount)
        }
    }

    func listItems(config: SourceConfiguration) async throws -> [SourceItem] {
        guard case .remarkable(let cfg) = config else {
            throw SourceError.wrongConfiguration(expected: .remarkable)
        }
        let files = try await remarkable.listFiles(inFolderId: cfg.folderId)
        return files.map {
            SourceItem(id: $0.id, name: $0.name, versionHash: $0.versionHash,
                       createdAt: $0.createdAt, tags: $0.tags)
        }
    }

    /// Ported verbatim from `SyncCoordinator.buildNoteContent`: typed text parsed
    /// straight from each page plus OCR of any handwriting, ordered by vertical
    /// position and combined across pages into one note. `ocrMode` deliberately
    /// does not gate OCR here — it only affects the skip decision in the engine,
    /// matching the prior behavior.
    func content(for item: SourceItem, config: SourceConfiguration) async throws -> NoteContent {
        guard case .remarkable(let cfg) = config else {
            throw SourceError.wrongConfiguration(expected: .remarkable)
        }
        let (defaultProvider, model) = await MainActor.run {
            (AppSettings.shared.ocrProvider, AppSettings.shared.ocrModel)
        }
        let ocr = OcrProviderFactory.make(provider: cfg.ocrProviderOverride ?? defaultProvider, model: model)

        let pages = (try? await remarkable.listPages(notebookId: item.id)) ?? []
        var blocks: [NoteBlock] = []
        for page in pages {
            let pageContent = (try? await remarkable.pageContent(for: page))
                ?? RemarkablePageContent(imageData: nil, typedText: [])
            let typedBlocks = pageContent.typedText.map(NoteContentBuilder.block(from:))

            var ocrBlocks: [NoteBlock] = []
            if let imageData = pageContent.imageData, !imageData.isEmpty {
                do {
                    let result = try await ocr.transcribe(imageData: imageData)
                    ocrBlocks = NoteContentBuilder.blocks(fromOCRText: result.text)
                    if let mermaid = result.mermaidSource { ocrBlocks.append(.mermaid(mermaid)) }
                } catch {
                    Log.ocr.error("OCR failed for item \(item.id, privacy: .public): \(Formatters.userMessage(for: error), privacy: .public)")
                }
            }

            if pageContent.typedTextFirst {
                blocks.append(contentsOf: typedBlocks + ocrBlocks)
            } else {
                blocks.append(contentsOf: ocrBlocks + typedBlocks)
            }
        }
        return NoteContent(blocks: blocks, provider: ocr.name, model: nil)
    }

    /// Ported verbatim from `RulesEngine.resolveTitle`, reading the strategy from
    /// the reMarkable source config (a binding may override it).
    func resolveTitle(for item: SourceItem,
                      content: NoteContent,
                      config: SourceConfiguration,
                      strategyOverride: TitleStrategy?) -> String {
        guard case .remarkable(let cfg) = config else { return item.name }
        let strategy = strategyOverride ?? cfg.titleStrategy
        let folderName = cfg.folderName

        switch strategy {
        case .fileName:
            return item.name.isEmpty ? folderName : item.name
        case .firstLineOfOcr:
            if let firstLine = content.plainText
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !firstLine.isEmpty, firstLine != "[blank page]" {
                return firstLine
            }
            return item.name.isEmpty ? folderName : item.name
        case .template:
            let context = TitleTemplateContext(
                notebook: item.name,
                pageNumber: 1,
                date: item.createdAt,
                title: item.name,
                folderName: folderName
            )
            return context.apply(to: cfg.titleTemplate ?? defaultTitleTemplate)
        }
    }

    /// reMarkable skips an item only when OCR is turned off (`ocrMode == .none`)
    /// and the page came back blank — the exact gate the old `RulesEngine.evaluate`
    /// applied, with the binding's OCR-mode override honored.
    func shouldSkipAsEmpty(content: NoteContent,
                           config: SourceConfiguration,
                           ocrModeOverride: OcrMode?) -> Bool {
        guard case .remarkable(let cfg) = config else { return false }
        let mode = ocrModeOverride ?? cfg.ocrMode
        let text = content.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        return mode == .none && (text.isEmpty || text == "[blank page]")
    }
}
