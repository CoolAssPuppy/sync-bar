//
//  Sources.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  A source is a place Sync Bar pulls notes FROM. reMarkable is the only one
//  today, but the kind is modeled separately from the data layer so adding a
//  new source is a matter of a new case plus its brand mark - the UI already
//  renders any SourceKind through SourceIcon / SourceMark.
//

import Foundation

enum SourceKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case remarkable

    var id: String { rawValue }

    var label: String {
        switch self {
        case .remarkable: return "reMarkable"
        }
    }

    /// One-line description for pickers and empty states.
    var subtitle: String {
        switch self {
        case .remarkable: return "Tablet notebooks and documents"
        }
    }

    /// SF Symbol fallback when the bundled brand asset is missing.
    var systemImage: String {
        switch self {
        case .remarkable: return "rectangle.portrait.on.rectangle.portrait"
        }
    }

    /// Brand asset shipped in `Images.xcassets`.
    var assetName: String {
        switch self {
        case .remarkable: return "Remarkable"
        }
    }

    /// Whether the brand mark is a single-color silhouette that must be tinted
    /// to stay visible across themes (see DestinationKind for the same idea).
    var brandMarkIsMonochrome: Bool {
        switch self {
        case .remarkable: return false
        }
    }
}
