//
//  RulesEngine.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// Default template applied when the user picks "Template" but hasn't
/// customized one yet. Centralized so the rule sheet, engine, and any
/// future migration code use the same string.
let defaultTitleTemplate = "{folder_name} – {notebook}"

/// Pure logic. Decides what to do with a given file (note) for a given rule.
/// A rule targets a folder; each file in it becomes one note.
struct RulesEngine {
    enum Directive: Equatable {
        case create(title: String)
        case skip(reason: SkipReason)
    }

    enum SkipReason: String, Equatable {
        case unchanged
        case ruleDisabled
        case ocrSkippedAndEmpty
    }

    func evaluate(rule: SyncRule, file: RmFile, folderName: String, ocrText: String?, previouslySyncedHash: String?) -> Directive {
        guard rule.enabled else { return .skip(reason: .ruleDisabled) }

        if let lastHash = previouslySyncedHash, lastHash == file.versionHash {
            return .skip(reason: .unchanged)
        }

        let text = (ocrText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if rule.ocrMode == .none && (text.isEmpty || text == "[blank page]") {
            return .skip(reason: .ocrSkippedAndEmpty)
        }

        return .create(title: resolveTitle(rule: rule, file: file, folderName: folderName, ocrText: ocrText))
    }

    func resolveTitle(rule: SyncRule, file: RmFile, folderName: String, ocrText: String?) -> String {
        switch rule.titleStrategy {
        case .fileName:
            return file.name.isEmpty ? folderName : file.name
        case .firstLineOfOcr:
            if let firstLine = ocrText?
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !firstLine.isEmpty, firstLine != "[blank page]" {
                return firstLine
            }
            return file.name.isEmpty ? folderName : file.name
        case .template:
            let context = TitleTemplateContext(
                notebook: file.name,
                pageNumber: 1,
                date: file.createdAt,
                title: file.name,
                folderName: folderName
            )
            return context.apply(to: rule.titleTemplate ?? defaultTitleTemplate)
        }
    }
}
