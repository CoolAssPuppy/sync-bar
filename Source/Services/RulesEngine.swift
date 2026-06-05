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

/// Pure logic. The source-agnostic decision of whether one item should sync now.
/// Title resolution and "is this content empty?" are source-specific and live on
/// the `SourceClient` (e.g. `RemarkableSourceClient`); the engine only combines
/// the generic signals: rule enabled, content unchanged, and a source-provided
/// "suppress as empty" flag.
struct RulesEngine {
    enum Directive: Equatable {
        case proceed
        case skip(reason: SkipReason)
    }

    enum SkipReason: String, Equatable {
        case unchanged
        case ruleDisabled
        case ocrSkippedAndEmpty
    }

    func evaluate(enabled: Bool,
                  itemVersionHash: String,
                  previouslySyncedHash: String?,
                  suppressedAsEmpty: Bool) -> Directive {
        guard enabled else { return .skip(reason: .ruleDisabled) }

        if let lastHash = previouslySyncedHash, lastHash == itemVersionHash {
            return .skip(reason: .unchanged)
        }

        if suppressedAsEmpty {
            return .skip(reason: .ocrSkippedAndEmpty)
        }

        return .proceed
    }
}
