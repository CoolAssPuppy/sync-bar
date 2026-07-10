//
//  AppleNotesDestinationClient.swift
//  SyncBar
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

    func write(payload: DestinationPayload, configuration: DestinationConfiguration, existingExternalId: String?) async throws -> DestinationWriteResult {
        guard case .appleNotes(let config) = configuration else {
            throw DestinationError.wrongConfiguration(expected: .appleNotes)
        }
        let folderName = Self.targetFolder(payload: payload, config: config)

        // Notes uses HTML for body rendering. Convert the OCR output into a
        // basic HTML structure with the mermaid diagram inlined as <pre>.
        let bodyHtml = Self.buildHtml(payload: payload)
        // Update the note we made before when we have its id; the script falls
        // back to creating one if it was deleted in Notes.
        let script: String
        if let existingExternalId, !existingExternalId.isEmpty {
            script = Self.updateScriptSource(noteId: existingExternalId, folderName: folderName, title: payload.title, bodyHtml: bodyHtml, creationDate: payload.sourceDate)
        } else {
            script = Self.appleScriptSource(folderName: folderName, title: payload.title, bodyHtml: bodyHtml, creationDate: payload.sourceDate)
        }

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
                notes: "Synced to folder \"\(folderName)\""
            )
        }.value
    }

    /// Lists the folder names in the local iCloud Notes account so the binding
    /// form can offer them. Runs off the main actor (Apple Events block).
    static func listFolders() async throws -> [String] {
        let script = """
        tell application "Notes"
            tell account "iCloud"
                set out to ""
                repeat with f in folders
                    set out to out & (name of f) & linefeed
                end repeat
                return out
            end tell
        end tell
        """
        return try await Task.detached(priority: .userInitiated) { () throws -> [String] in
            var errorInfo: NSDictionary?
            guard let appleScript = NSAppleScript(source: script) else {
                throw DestinationError.scriptFailed("Couldn't construct Apple Notes script.")
            }
            let descriptor = appleScript.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let message = errorInfo["NSAppleScriptErrorMessage"] as? String ?? "Couldn't read Apple Notes folders."
                throw DestinationError.scriptFailed(message)
            }
            let names = (descriptor.stringValue ?? "")
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            // De-dupe (a name can repeat across sub-accounts) while keeping order.
            var seen = Set<String>()
            return names.filter { seen.insert($0).inserted }
        }.value
    }

    /// The iCloud notebook a note lands in. A source that carries a per-item
    /// folder (Notion's Category, on `payload.folderPath`) routes each note into a
    /// notebook of that name, so a database fans out across notebooks the way it
    /// fans out across Markdown folders. Sources with no per-item folder
    /// (reMarkable) fall back to the binding's single configured folder, and an
    /// empty configured folder falls back to "Notes" (the default notebook).
    static func targetFolder(payload: DestinationPayload, config: AppleNotesDestinationConfig) -> String {
        if let category = payload.folderPath.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return category
        }
        return config.folderName.isEmpty ? "Notes" : config.folderName
    }

    // MARK: Script building (internal for testing)

    /// Builds the AppleScript that creates or reuses the iCloud folder and adds
    /// the note. Every interpolated value runs through `escape`, since titles,
    /// folder names, and OCR'd body text are user-controlled and would
    /// otherwise allow AppleScript injection.
    static func appleScriptSource(folderName: String, title: String, bodyHtml: String, creationDate: Date? = nil) -> String {
        """
        tell application "Notes"
            tell account "iCloud"
                if not (exists folder "\(escape(folderName))") then
                    make new folder with properties {name:"\(escape(folderName))"}
                end if
                tell folder "\(escape(folderName))"
        \(dateSetup(creationDate))set newNote to make new note with properties {name:"\(escape(title))", body:"\(escape(bodyHtml))"\(dateProperties(creationDate))}
                    return id of newNote
                end tell
            end tell
        end tell
        """
    }

    /// AppleScript that builds `theDate` from a Swift Date's components. Apple
    /// Notes only accepts a note's creation/modification date AT creation time
    /// (both are read-only afterward), so this is emitted right before the
    /// `make new note` call. Components are set as integers (no injection surface);
    /// day is reset to 1 first so setting a shorter month can't roll the date over.
    static func dateSetup(_ date: Date?, varName: String = "theDate") -> String {
        guard let date else { return "" }
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let indent = "            "
        return """
        \(indent)set \(varName) to (current date)
        \(indent)set day of \(varName) to 1
        \(indent)set year of \(varName) to \(c.year ?? 2000)
        \(indent)set month of \(varName) to \(c.month ?? 1)
        \(indent)set day of \(varName) to \(c.day ?? 1)
        \(indent)set hours of \(varName) to \(c.hour ?? 0)
        \(indent)set minutes of \(varName) to \(c.minute ?? 0)
        \(indent)set seconds of \(varName) to \(c.second ?? 0)

        """
    }

    /// The `creation date`/`modification date` properties for a `make new note`,
    /// or empty when no date is being preserved. Both are set so the note doesn't
    /// surface as "modified just now" in a date-sorted list.
    static func dateProperties(_ date: Date?, varName: String = "theDate") -> String {
        date == nil ? "" : ", creation date:\(varName), modification date:\(varName)"
    }

    /// Updates the body of an existing note (found by id). If that note no
    /// longer exists, falls back to creating one in the folder so an edit still
    /// lands somewhere. Setting the body (whose first line is an `<h1>` title)
    /// also updates the note's displayed name.
    static func updateScriptSource(noteId: String, folderName: String, title: String, bodyHtml: String, creationDate: Date? = nil) -> String {
        """
        tell application "Notes"
            tell account "iCloud"
                try
                    set theNote to note id "\(escape(noteId))"
                    set body of theNote to "\(escape(bodyHtml))"
                    return id of theNote
                on error
                    if not (exists folder "\(escape(folderName))") then
                        make new folder with properties {name:"\(escape(folderName))"}
                    end if
                    tell folder "\(escape(folderName))"
        \(dateSetup(creationDate))set newNote to make new note with properties {name:"\(escape(title))", body:"\(escape(bodyHtml))"\(dateProperties(creationDate))}
                        return id of newNote
                    end tell
                end try
            end tell
        end tell
        """
    }

    static func buildHtml(payload: DestinationPayload) -> String {
        let title = "<h1>\(htmlEscape(payload.title))</h1>"
        let body = payload.blocks.isEmpty ? bodyHtml(payload: payload) : blocksHtml(payload.blocks)
        return title + "\n" + body
    }

    /// Renders structured blocks to Notes-flavored HTML. Notes' AppleScript
    /// `body` can't create native tappable checklists, so checkbox items use
    /// ballot-box glyphs (☐ / ☑) and strike completed items, mirroring how
    /// reMarkable itself shows a ticked box.
    private static func blocksHtml(_ blocks: [NoteBlock]) -> String {
        var html: [String] = []
        var listOpen = false
        func closeList() {
            if listOpen { html.append("</ul>"); listOpen = false }
        }
        func openList() {
            if !listOpen { html.append("<ul>"); listOpen = true }
        }
        for block in blocks {
            switch block {
            case .heading(let text):
                closeList(); html.append("<h2>\(htmlEscape(text))</h2>")
            case .paragraph(let text):
                closeList(); html.append("<p>\(lineBreaks(htmlEscape(text)))</p>")
            case .bullet(let text):
                openList(); html.append("<li>\(htmlEscape(text))</li>")
            case .checkbox(let text, let checked):
                openList()
                let mark = checked ? "&#9745;" : "&#9744;"               // ☑ / ☐
                let label = checked ? "<s>\(htmlEscape(text))</s>" : htmlEscape(text)
                html.append("<li>\(mark) \(label)</li>")
            case .mermaid(let source):
                closeList(); html.append("<pre>\(htmlEscape(source))</pre>")
            case .image(let url):
                // Notes' AppleScript body can't embed remote images; a
                // clickable link is the faithful fallback.
                closeList()
                let escaped = htmlEscape(url.absoluteString)
                html.append("<p><a href=\"\(escaped)\">\(escaped)</a></p>")
            }
        }
        closeList()
        return html.joined(separator: "\n")
    }

    /// Legacy path for payloads without structured blocks: the flattened body
    /// as a paragraph, plus any Mermaid diagram as a `<pre>` block.
    private static func bodyHtml(payload: DestinationPayload) -> String {
        var html = "<p>\(lineBreaks(htmlEscape(payload.body)))</p>"
        if let mermaid = payload.mermaidSource {
            html += "\n<pre>\(htmlEscape(mermaid))</pre>"
        }
        return html
    }

    private static func lineBreaks(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "<br>")
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
