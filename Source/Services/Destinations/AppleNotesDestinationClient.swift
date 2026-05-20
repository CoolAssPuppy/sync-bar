//
//  AppleNotesDestinationClient.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation
import AppKit

/// Creates a note in Apple Notes via AppleScript. Works on any Mac signed
/// in to iCloud Notes - no OAuth required, no third-party tokens. Sending the
/// Apple Event requires the automation entitlement plus the
/// NSAppleEventsUsageDescription consent string (see Info.plist / entitlements).
struct AppleNotesDestinationClient: DestinationClient {
    let kind: DestinationKind = .appleNotes

    func write(payload: DestinationPayload, configuration: DestinationConfiguration) async throws -> DestinationWriteResult {
        guard case .appleNotes(let config) = configuration else {
            throw DestinationError.wrongConfiguration(expected: .appleNotes)
        }
        let folderName = config.folderName.isEmpty ? "Notes" : config.folderName

        // Notes uses HTML for body rendering. Convert the OCR output into a
        // basic HTML structure with the mermaid diagram inlined as <pre>.
        let bodyHtml = Self.buildHtml(payload: payload)
        let script = Self.appleScriptSource(folderName: folderName, title: payload.title, bodyHtml: bodyHtml)

        return try await Task.detached(priority: .userInitiated) { () throws -> DestinationWriteResult in
            var errorInfo: NSDictionary?
            guard let appleScript = NSAppleScript(source: script) else {
                throw DestinationError.scriptFailed("Couldn't construct Apple Notes script.")
            }
            let descriptor = appleScript.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let message = errorInfo["NSAppleScriptErrorMessage"] as? String ?? "Apple Notes script failed."
                throw DestinationError.scriptFailed(message)
            }
            let noteId = descriptor.stringValue ?? UUID().uuidString
            return DestinationWriteResult(
                externalId: noteId,
                externalURL: nil,
                notes: "Created in folder \"\(folderName)\""
            )
        }.value
    }

    // MARK: Script building (internal for testing)

    /// Builds the AppleScript that creates or reuses the iCloud folder and adds
    /// the note. Every interpolated value runs through `escape`, since titles,
    /// folder names, and OCR'd body text are user-controlled and would
    /// otherwise allow AppleScript injection.
    static func appleScriptSource(folderName: String, title: String, bodyHtml: String) -> String {
        """
        tell application "Notes"
            tell account "iCloud"
                if not (exists folder "\(escape(folderName))") then
                    make new folder with properties {name:"\(escape(folderName))"}
                end if
                tell folder "\(escape(folderName))"
                    set newNote to make new note with properties {name:"\(escape(title))", body:"\(escape(bodyHtml))"}
                    return id of newNote
                end tell
            end tell
        end tell
        """
    }

    static func buildHtml(payload: DestinationPayload) -> String {
        let escapedTitle = htmlEscape(payload.title)
        let escapedBody = htmlEscape(payload.body)
        let mermaidBlock = payload.mermaidSource.map {
            "<pre>\(htmlEscape($0))</pre>"
        } ?? ""
        return """
        <h1>\(escapedTitle)</h1>
        <p>\(escapedBody.replacingOccurrences(of: "\n", with: "<br>"))</p>
        \(mermaidBlock)
        """
    }

    static func htmlEscape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Escapes a value for embedding in an AppleScript double-quoted string.
    /// Carriage returns and newlines are normalized to `\n` first because a
    /// raw line break terminates an AppleScript string literal; backslashes are
    /// doubled before quotes and newlines so the added escapes aren't re-escaped.
    static func escape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
           .replacingOccurrences(of: "\r", with: "\n")
           .replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
           .replacingOccurrences(of: "\n", with: "\\n")
    }
}
