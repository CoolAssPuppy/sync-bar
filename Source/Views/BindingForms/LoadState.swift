//
//  LoadState.swift
//  Sync Bar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// Async load state for a fetched list (folders, tags, schema).
enum LoadState<T> {
    case idle
    case loading
    case loaded(T)
    case failed(String)
}
