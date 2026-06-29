//
//  TimeZone+Pacific.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

extension TimeZone {
    /// The fixed reset time zone for paid features — the monthly read-cap reset
    /// and the daily entitlement re-check both anchor to it, so a "day"/"month"
    /// boundary is the same for everyone regardless of their local zone. Falls back
    /// to the current zone only if the identifier somehow can't be resolved.
    static let pacific = TimeZone(identifier: "America/Los_Angeles") ?? .current
}
