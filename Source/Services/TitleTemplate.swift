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

    var placeholder: String { "{\(rawValue)}" }

    var helpText: String {
        switch self {
        case .folderName: return "Containing folder name"
        case .notebook:   return "Note (file) name"
        case .pageNumber: return "1-indexed page number"
        case .date:       return "Note creation date (yyyy-MM-dd)"
        case .today:      return "Today's date when synced (yyyy-MM-dd)"
        case .title:      return "Resolved note title"
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
