//
//  URL+StaticString.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

extension URL {
    /// Builds a URL from a compile-time string literal. `StaticString` accepts
    /// only literals, so a malformed value is a programmer error that traps the
    /// first time the path runs -- the same guarantee as a force-unwrap, without
    /// the `!` the lint policy forbids on runtime values.
    init(staticString: StaticString) {
        guard let url = URL(string: "\(staticString)") else {
            preconditionFailure("Invalid static URL literal: \(staticString)")
        }
        self = url
    }
}
