//
//  SyncFlow.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The redesign's atomic object. A "Sync" the user sees = one (rule, binding)
//  pair: one source scope flowing to one destination with its options. Rules
//  and bindings stay as the storage model; this flattens them into the single
//  noun the new UI is built around.
//

import Foundation

struct SyncFlow: Identifiable, Equatable, Hashable {
    let rule: SyncRule
    let binding: DestinationBinding

    var id: String { binding.id }
    var ruleId: String { rule.id }

    var folderId: String { rule.remarkableConfig?.folderId ?? "" }
    var folderName: String { rule.sourceSummary }
    var kind: DestinationKind { binding.kind }
    var destinationSummary: String { binding.configuration.summary }

    /// Per-sync where possible: title and OCR fall back to the rule's defaults
    /// but a binding override (which the editor writes) makes them per-sync.
    var titleStrategy: TitleStrategy { binding.titleStrategyOverride ?? rule.remarkableConfig?.titleStrategy ?? .firstLineOfOcr }
    var ocrMode: OcrMode { binding.ocrModeOverride ?? rule.remarkableConfig?.ocrMode ?? .all }
    var requiredTags: [String] { binding.effectiveRequiredTags ?? [] }

    var isEnabled: Bool { binding.enabled && rule.enabled }
    var lastRunAt: Date? { binding.lastRunAt }

    var status: RuleRunStatus {
        guard isEnabled else { return .neverRun }
        return binding.lastRunStatus
    }

    /// The Twitter stream this sync pulls (Bookmarks / Likes / Posts), or nil
    /// when the source isn't Twitter.
    private var xStreamLabel: String? {
        if case .x(let cfg) = rule.source { return cfg.stream.label }
        return nil
    }

    /// The muted one-line summary under a sync row.
    var howSummary: String {
        // Title strategy and OCR describe handwriting, so they belong to
        // reMarkable alone. Every other source says what's flowing where; a Notion
        // page has a title already and nothing to run OCR over.
        guard rule.sourceKind == .remarkable else { return flowSummary }
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

    /// What a non-reMarkable sync moves, and where to.
    private var flowSummary: String {
        if let stream = xStreamLabel { return "Syncing \(stream) to \(destinationSummary)" }
        if rule.sourceKind == .safari {
            if case .chrome(let cfg) = binding.configuration {
                return cfg.mirrorExactly ? "Exactly matches Safari" : "Adds & updates bookmarks"
            }
            return "Bookmarks"
        }
        return "Syncing \(rule.sourceSummary) to \(destinationSummary)"
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

    /// Count of destination accounts connected (any kind). Must mirror
    /// `connectedApps`, the editor's "To" list, so the two never disagree.
    var connectedAppCount: Int {
        notionWorkspaces.count + linearAccounts.count + googleAccounts.count
            + markdownTargets.count + appleNotesTargets.count + chromeTargets.count
    }

    var hasAnyDestination: Bool { connectedAppCount > 0 }

    /// Every source kind the user can build a sync from. Notion counts: one
    /// connected workspace both reads (database backup) and writes, so the same
    /// connection serves as a source. Reminders is excluded because it's only ever
    /// half of a two-way task sync, never a one-way source — see `hasAnySource`.
    ///
    /// This is the single source of truth for "which sources exist". Anything
    /// asking that question reads it rather than keeping its own list, which is
    /// how the home screen and the editor drifted apart.
    var connectedSourceKinds: [SourceKind] {
        var out: [SourceKind] = []
        if remarkableAccount != nil { out.append(.remarkable) }
        if safariConnected          { out.append(.safari) }
        if !notionWorkspaces.isEmpty { out.append(.notion) }
        if !xAccounts.isEmpty        { out.append(.x) }
        return out
    }

    /// Whether the user has anything to sync from at all, counting Reminders,
    /// which yields a two-way task sync rather than a one-way flow.
    var hasAnySource: Bool { !connectedSourceKinds.isEmpty || remindersConnected }

    /// Count of the source cards on the Connections screen: reMarkable, Safari and
    /// Reminders are single "added it" flags, Twitter is one card per account.
    /// Notion is deliberately absent — it appears once, under Destinations, even
    /// though `connectedSourceKinds` also offers it as a source.
    var connectedSourceCount: Int {
        (remarkableAccount != nil ? 1 : 0) + (safariConnected ? 1 : 0)
            + (remindersConnected ? 1 : 0) + xAccounts.count
    }

    /// Everything shown on the Connections screen: sources + destinations. This
    /// is what the "Connections" rail badge should reflect.
    var connectionCount: Int { connectedSourceCount + connectedAppCount }
}
