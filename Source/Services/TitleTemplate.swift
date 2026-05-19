//
//  TitleTemplate.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// Tokens the user can use in title templates and Markdown file-name
/// templates. Adding one means: add a case, give it a placeholder string,
/// and supply a value in `Context`.
enum TitleToken: String, CaseIterable {
    case notebook
    case pageNumber  = "page_n"
    case date
    case title

    var placeholder: String { "{\(rawValue)}" }

    var helpText: String {
        switch self {
        case .notebook:   return "Source reMarkable notebook"
        case .pageNumber: return "1-indexed page number"
        case .date:       return "Page creation date (yyyy-MM-dd)"
        case .title:      return "Resolved page title"
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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    func value(for token: TitleToken) -> String {
        switch token {
        case .notebook:   return notebook
        case .pageNumber: return "\(pageNumber)"
        case .date:       return Self.dateFormatter.string(from: date)
        case .title:      return title
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
        let tokens = TitleToken.allCases.map(\.placeholder).joined(separator: ", ")
        return "Tokens: \(tokens)"
    }()
}
