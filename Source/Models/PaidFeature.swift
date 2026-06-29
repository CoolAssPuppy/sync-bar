//
//  PaidFeature.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  A "paid Sync class": a set of syncs that require a paid subscription because
//  they cost the maker money (e.g. the X API read budget). Twitter is the first
//  instance. Everything that gates on payment routes through this abstraction —
//  never a bare `.x` check — so a future paywall over another source, a single
//  sync, or a group is a data change here, not a sweep through the codebase.
//

import Foundation

enum PaidFeature: String, CaseIterable, Codable, Sendable, Identifiable {
    case twitter

    var id: String { rawValue }

    /// The source kinds that belong to this paid class today. The mapping is the
    /// one place that decides what costs money; widen it (or move to per-sync /
    /// per-group membership) without touching the gates.
    var sourceKinds: Set<SourceKind> {
        switch self {
        case .twitter: return [.x]
        }
    }

    /// How the paywall and Settings name this class to the user.
    var displayName: String {
        switch self {
        case .twitter: return "Twitter"
        }
    }

    /// Monthly base price shown in the paywall. Usage is metered on top.
    var monthlyPriceLabel: String {
        switch self {
        case .twitter: return "$4.99/month"
        }
    }
}

extension SourceKind {
    /// The paid class this source belongs to, or nil when the source is free.
    var paidFeature: PaidFeature? {
        PaidFeature.allCases.first { $0.sourceKinds.contains(self) }
    }
}
