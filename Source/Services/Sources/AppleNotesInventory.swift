//
//  AppleNotesInventory.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Reads the local iCloud Notes account into `[ExistingAppleNote]` for first-run
//  adoption: notebook, title, creation date, and the note's AppleScript id (the
//  same `x-coredata://…` id `AppleNotesDestinationClient.write` returns, so a
//  matched note can be updated in place). The creation date is emitted as
//  Y-M-D components inside AppleScript to dodge locale-formatted date strings,
//  and titles are stripped of tabs/newlines so the TSV stays one record per line.
//

import Foundation

enum AppleNotesInventory {

    /// Every note in the iCloud account (Recently Deleted excluded). One AppleScript
    /// pass; bulk-fetches per folder so a few thousand notes read in a couple of
    /// seconds. Runs off the main actor (Apple Events block).
    static func read() async throws -> [ExistingAppleNote] {
        let raw = try await Task.detached(priority: .userInitiated) { () throws -> String in
            var errorInfo: NSDictionary?
            guard let script = NSAppleScript(source: scriptSource) else {
                throw DestinationError.scriptFailed("Couldn't construct the Apple Notes inventory script.")
            }
            let descriptor = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let message = errorInfo["NSAppleScriptErrorMessage"] as? String ?? "Couldn't read Apple Notes."
                throw DestinationError.scriptFailed(message)
            }
            return descriptor.stringValue ?? ""
        }.value
        return parse(raw)
    }

    /// Parses the `folder<TAB>YYYY-MM-DD<TAB>id<TAB>name` lines the script emits.
    /// Tolerant: a malformed line is skipped, not fatal.
    static func parse(_ raw: String) -> [ExistingAppleNote] {
        raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 4 else { return nil }
            let notebook = parts[0]
            guard let created = date(from: parts[1]) else { return nil }
            let noteId = parts[2]
            let title = parts[3...].joined(separator: "\t")
            guard !noteId.isEmpty else { return nil }
            return ExistingAppleNote(noteId: noteId, notebook: notebook, title: title, createdAt: created)
        }
    }

    private static func date(from ymd: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: ymd)
    }

    private static let scriptSource = """
    on pad(n)
        set s to (n as integer) as string
        if length of s < 2 then set s to "0" & s
        return s
    end pad
    tell application "Notes"
        set folderNames to name of folders of account "iCloud"
    end tell
    set output to ""
    repeat with fName in folderNames
        set fn to fName as string
        if fn is not "Recently Deleted" then
            tell application "Notes"
                set ns to name of notes of folder fn of account "iCloud"
                set cs to creation date of notes of folder fn of account "iCloud"
                set ids to id of notes of folder fn of account "iCloud"
            end tell
            set cnt to count of ns
            repeat with i from 1 to cnt
                set theDate to item i of cs
                set y to year of theDate as integer
                set m to my pad(month of theDate as integer)
                set d to my pad(day of theDate)
                set AppleScript's text item delimiters to {return, linefeed, tab}
                set parts to text items of (item i of ns as string)
                set AppleScript's text item delimiters to " "
                set cleanName to parts as string
                set AppleScript's text item delimiters to ""
                set output to output & fn & tab & (y as string) & "-" & m & "-" & d & tab & (item i of ids as string) & tab & cleanName & linefeed
            end repeat
        end if
    end repeat
    return output
    """
}
