//
//  TitleTemplate.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// Tokens the user can use in title templates and Markdown file-name
/// templates. Adding one means: add a case, give it a placeholder string,
/// and supply a value in `Context`.
enum TitleToken: String, CaseIterable {
    case folderName  = "folder_name"
    case notebook
    case pageNumber  = "page_n"
    case date
    case today
    case title
    // Source-specific fields, resolved from each item's metadata (e.g. Twitter).
    // They expand to empty for sources that don't supply them.
    case author
    case authorName  = "author_name"
    case tweetUrl    = "tweet_url"
    case tweetId     = "tweet_id"
    case stream
    // Must stay the LAST case: `apply(to:)` substitutes in `allCases` order,
    // and the body goes in after every other pass so tokens appearing
    // literally inside synced text are never re-substituted.
    case text

    var placeholder: String { "{\(rawValue)}" }

    /// Source-specific tokens are hidden from the generic title-template hint so
    /// they don't clutter reMarkable/Markdown fields where they never apply.
    var isSourceSpecific: Bool {
        switch self {
        case .author, .authorName, .tweetUrl, .tweetId, .stream, .text: return true
        default: return false
        }
    }

    var helpText: String {
        switch self {
        case .folderName: return "Containing folder name"
        case .notebook:   return "Note (file) name"
        case .pageNumber: return "1-indexed page number"
        case .date:       return "Note creation date (yyyy-MM-dd)"
        case .today:      return "Today's date when synced (yyyy-MM-dd)"
        case .title:      return "Resolved note title"
        case .author:     return "Author handle (@username)"
        case .authorName: return "Author display name"
        case .tweetUrl:   return "Canonical tweet URL"
        case .tweetId:    return "Tweet id"
        case .stream:     return "Stream (bookmarks / likes / posts)"
        case .text:       return "Full synced text (tweet + thread)"
        }
    }
}

/// Inputs used to fill the templates. Both the rules engine and the
/// Markdown destination client build one of these and call `apply`.
struct TitleTemplateContext {
    var notebook: String
    var pageNumber: Int
    var date: Date
    var title: String
    /// Containing folder name (the rule's subject). Defaults to empty.
    var folderName: String = ""
    /// "Today" at resolution time. Defaults to now; injectable for tests.
    var today: Date = Date()
    /// Source-specific fields (e.g. Twitter author / canonical URL / stream),
    /// keyed as the source emits them in `SourceItem.metadata`.
    var metadata: [String: String] = [:]
    /// The full synced body for `{text}`. Only column-value templates populate
    /// it — file-name templates leave it empty so `{text}` can't explode a name.
    var body: String = ""

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    func value(for token: TitleToken) -> String {
        switch token {
        case .folderName: return folderName
        case .notebook:   return notebook
        case .pageNumber: return "\(pageNumber)"
        case .date:       return Self.dateFormatter.string(from: date)
        case .today:      return Self.dateFormatter.string(from: today)
        case .title:      return title
        case .author:     return metadata["author"] ?? ""
        case .authorName: return metadata["author_name"] ?? ""
        case .tweetUrl:   return metadata["canonical_url"] ?? ""
        case .tweetId:    return metadata["id"] ?? ""
        case .stream:     return metadata["stream"] ?? ""
        case .text:       return body
        }
    }

    func apply(to template: String) -> String {
        var output = template
        for token in TitleToken.allCases {
            output = output.replacingOccurrences(of: token.placeholder, with: value(for: token))
        }
        return output
    }
}

/// Help line shown beneath template text fields in the UI so users know
/// what tokens are available.
enum TitleTemplateHelp {
    static let inlineHint: String = {
        let tokens = TitleToken.allCases
            .filter { !$0.isSourceSpecific }
            .map(\.placeholder)
            .joined(separator: ", ")
        return "Tokens: \(tokens)"
    }()
}
