//
//  RulesEngine.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// Default template applied when the user picks "Template" but hasn't
/// customized one yet. Centralized so the rule sheet, engine, and any
/// future migration code use the same string.
let defaultTitleTemplate = "{notebook} – page {page_n}"

/// Pure logic. Decides what to do with a given page for a given rule.
struct RulesEngine {
    enum Directive: Equatable {
        case create(title: String)
        case skip(reason: SkipReason)
    }

    enum SkipReason: String, Equatable {
        case unchanged
        case ocrEmpty
        case ruleDisabled
        case ocrSkippedAndPageEmpty
    }

    func evaluate(rule: SyncRule, page: RmPage, ocrText: String?, previouslySyncedHash: String?) -> Directive {
        guard rule.enabled else { return .skip(reason: .ruleDisabled) }

        if let lastHash = previouslySyncedHash, lastHash == page.versionHash {
            return .skip(reason: .unchanged)
        }

        if rule.ocrMode == .none && !page.hasTypedText {
            return .skip(reason: .ocrSkippedAndPageEmpty)
        }

        let title = resolveTitle(rule: rule, page: page, ocrText: ocrText)
        return .create(title: title)
    }

    func resolveTitle(rule: SyncRule, page: RmPage, ocrText: String?) -> String {
        switch rule.titleStrategy {
        case .firstLineOfOcr:
            if let firstLine = ocrText?
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !firstLine.isEmpty {
                return firstLine
            }
            return fallbackTitle(rule: rule, page: page)
        case .template:
            return applyTemplate(rule.titleTemplate ?? defaultTitleTemplate, rule: rule, page: page)
        case .pageNumber:
            return "Page \(page.positionInNotebook + 1)"
        case .rmCreatedDate:
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: page.createdAt)
        }
    }

    private func fallbackTitle(rule: SyncRule, page: RmPage) -> String {
        "\(rule.rmNotebookName) · page \(page.positionInNotebook + 1)"
    }

    private func applyTemplate(_ template: String, rule: SyncRule, page: RmPage) -> String {
        let context = TitleTemplateContext(
            notebook: rule.rmNotebookName,
            pageNumber: page.positionInNotebook + 1,
            date: page.createdAt,
            title: ""
        )
        return context.apply(to: template)
    }
}
