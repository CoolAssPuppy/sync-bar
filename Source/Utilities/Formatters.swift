//
//  Formatters.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

enum Formatters {
    /// `4:32 PM` style label for last-checked timestamps.
    static let shortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    /// `Mar 12 · 4:32 PM` for log rows. Date if not today, time always.
    static func logRowLabel(for date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        let timeOfDay = shortTime.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today · \(timeOfDay)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday · \(timeOfDay)"
        }
        let monthDay = DateFormatter()
        monthDay.dateFormat = "MMM d"
        return "\(monthDay.string(from: date)) · \(timeOfDay)"
    }

    /// `2 minutes ago` style relative label for menu bar rows.
    static func relativeLabel(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Builds a friendly "3 notes synced" / "1 note synced" / "Nothing to sync" string.
    static func syncResultLabel(pageCount: Int) -> String {
        switch pageCount {
        case 0:  return "Nothing to sync"
        case 1:  return "1 note synced"
        default: return "\(pageCount) notes synced"
        }
    }

    /// User-presentable summary of any error. Prefer `LocalizedError.errorDescription`
    /// when available so we don't leak raw `\(error)` strings into the UI.
    static func userMessage(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return (error as NSError).localizedDescription
    }
}
