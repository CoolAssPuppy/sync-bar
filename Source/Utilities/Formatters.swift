//
//  Formatters.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

enum Formatters {
    /// Parses an ISO 8601 timestamp, tolerating both fractional-second
    /// (`2026-06-20T12:00:00.000Z`) and plain (`2026-06-20T12:00:00Z`) forms —
    /// the two shapes the X, Notion, and Polar APIs all return interchangeably.
    static func parseISO8601(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

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
        // Under a minute reads as "just now" rather than the awkward "0 sec".
        if abs(date.timeIntervalSinceNow) < 60 { return "just now" }
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
