//
//  SyncFlow.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The redesign's atomic object. A "Sync" the user sees = one (rule, binding)
//  pair: a reMarkable folder flowing to one destination with its options. Rules
//  and bindings stay as the storage model; this flattens them into the single
//  noun the new UI is built around.
//

import Foundation

struct SyncFlow: Identifiable, Equatable, Hashable {
    let rule: SyncRule
    let binding: DestinationBinding

    var id: String { binding.id }
    var ruleId: String { rule.id }

    var folderId: String { rule.rmNotebookId }
    var folderName: String { rule.rmNotebookName }
    var kind: DestinationKind { binding.kind }
    var destinationSummary: String { binding.configuration.summary }

    /// Per-sync where possible: title and OCR fall back to the rule's defaults
    /// but a binding override (which the editor writes) makes them per-sync.
    var titleStrategy: TitleStrategy { binding.titleStrategyOverride ?? rule.titleStrategy }
    var ocrMode: OcrMode { binding.ocrModeOverride ?? rule.ocrMode }
    var requiredTags: [String] { binding.effectiveRequiredTags ?? [] }

    var isEnabled: Bool { binding.enabled && rule.enabled }
    var lastRunAt: Date? { binding.lastRunAt }

    var status: RuleRunStatus {
        guard isEnabled else { return .neverRun }
        return binding.lastRunStatus
    }

    /// The muted one-line summary under a sync row.
    var howSummary: String {
        var parts: [String] = [titleShort + " as title"]
        switch ocrMode {
        case .all:             parts.append("OCR all pages")
        case .handwrittenOnly: parts.append("OCR handwriting")
        case .none:            parts.append("no OCR")
        }
        if requiredTags.isEmpty {
            // keep it short — no filter is the common case
        } else {
            parts.append("tag: " + requiredTags.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    private var titleShort: String {
        switch titleStrategy {
        case .fileName:       return "File name"
        case .firstLineOfOcr: return "First line"
        case .template:       return "Template"
        }
    }
}

extension Ledger {
    /// Every sync flow, flattened across rules and their destination bindings,
    /// most-recently-run first.
    var syncFlows: [SyncFlow] {
        rules
            .flatMap { rule in rule.destinations.map { SyncFlow(rule: rule, binding: $0) } }
            .sorted { ($0.lastRunAt ?? .distantPast) > ($1.lastRunAt ?? .distantPast) }
    }

    /// Count of destination accounts connected (any kind).
    var connectedAppCount: Int {
        notionWorkspaces.count + linearAccounts.count + googleAccounts.count
            + markdownTargets.count + appleNotesTargets.count
    }

    var hasAnyDestination: Bool { connectedAppCount > 0 }
}
