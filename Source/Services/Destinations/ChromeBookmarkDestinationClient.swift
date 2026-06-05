//
//  ChromeBookmarkDestinationClient.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation
import AppKit

/// Writes Safari (or any) bookmarks into a Google Chrome profile. One-way
/// "ensure this URL exists in the target folder": idempotency is URL membership,
/// read from Chrome's JSON (always safe to read, even while Chrome runs).
///
/// Write path: the robust route edits Chrome's `Bookmarks` JSON and recomputes
/// its checksum, which requires Chrome to be quit (a live edit gets clobbered).
/// While Chrome is running, B4 adds an AppleScript create path; until then this
/// surfaces a clear "quit Chrome" message and the next closed-Chrome cycle
/// applies the write.
struct ChromeBookmarkDestinationClient: DestinationClient {
    let kind: DestinationKind = .chrome

    /// Test seams: point at a temp Bookmarks file, force the Chrome-running
    /// state, and stub AppleScript execution. nil in production (resolve the real
    /// profile path / NSRunningApplication / run the real script).
    var bookmarksURLOverride: URL? = nil
    var chromeRunningOverride: Bool? = nil
    var appleScriptRunner: (@Sendable (String) throws -> Void)? = nil

    func write(payload: DestinationPayload,
               configuration: DestinationConfiguration,
               existingExternalId: String?) async throws -> DestinationWriteResult {
        guard case .chrome(let config) = configuration else {
            throw DestinationError.wrongConfiguration(expected: .chrome)
        }
        guard let url = payload.url else {
            throw DestinationError.fileSystem("This item has no URL to bookmark.")
        }

        let bookmarksURL = bookmarksURLOverride ?? Self.bookmarksFileURL(profileDirName: config.profileDirName)
        guard let data = try? Data(contentsOf: bookmarksURL) else {
            throw DestinationError.fileSystem("Couldn't read Chrome bookmarks for profile \"\(config.profileDirName)\". Is Chrome installed?")
        }
        let store = try ChromeBookmarksStore(data: data)

        // Idempotent: already present in the target folder → nothing to write.
        if let existing = store.guid(forURL: url.absoluteString, inFolderPath: config.targetFolderPath) {
            return DestinationWriteResult(externalId: existing, externalURL: url, notes: "Already in Chrome")
        }

        // While Chrome is running the JSON file can't be touched (a live edit gets
        // clobbered), so create the bookmark live over AppleScript instead. It's
        // the fragile path: if it silently no-ops, the next Chrome-quit cycle's
        // URL-membership check creates the bookmark via the JSON path.
        if chromeRunningOverride ?? Self.isChromeRunning() {
            let source = Self.appleScriptSource(title: payload.title, url: url.absoluteString,
                                                folderPath: config.targetFolderPath)
            let runner = appleScriptRunner ?? { try Self.runAppleScript($0) }
            try await Task.detached(priority: .userInitiated) { try runner(source) }.value
            // Best-effort guid: Chrome may not have flushed the JSON yet, so fall
            // back to the URL as the external id (idempotency re-reads by URL anyway).
            let guid = (try? Data(contentsOf: bookmarksURL))
                .flatMap { try? ChromeBookmarksStore(data: $0) }?
                .guid(forURL: url.absoluteString, inFolderPath: config.targetFolderPath)
            return DestinationWriteResult(externalId: guid ?? url.absoluteString, externalURL: url,
                                          notes: "Added to Chrome via AppleScript")
        }

        // Chrome is quit: the robust path — mutate the JSON and recompute the checksum.
        let guid = try store.addBookmark(name: payload.title, url: url.absoluteString, folderPath: config.targetFolderPath)
        try Self.writeAtomically(try store.serialized(), to: bookmarksURL)
        return DestinationWriteResult(externalId: guid, externalURL: url,
                                      notes: "Added to Chrome (\(config.profileDirName))")
    }

    // MARK: Helpers

    static func bookmarksFileURL(profileDirName: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/\(profileDirName)/Bookmarks")
    }

    static func isChromeRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty
    }

    /// Atomic write of the Bookmarks file, refreshing Bookmarks.bak alongside it
    /// (Chrome's own backup) so a half-write can't strand the user.
    private static func writeAtomically(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
            try? data.write(to: url.appendingPathExtension("bak"), options: .atomic)
        } catch {
            throw DestinationError.fileSystem("Couldn't write Chrome bookmarks: \(error.localizedDescription)")
        }
    }

    // MARK: AppleScript (live path; internal for testing the generated source)

    /// Builds the AppleScript that finds-or-creates the target folder path and
    /// adds a bookmark item. The first path component selects a Chrome root
    /// (Bookmarks Bar / Other Bookmarks); the rest are nested folders. Every
    /// interpolated value is escaped (titles/URLs are user-controlled).
    static func appleScriptSource(title: String, url: String, folderPath: [String]) -> String {
        let rootSpecifier: String
        switch ChromeBookmarksStore.rootKey(for: folderPath.first ?? "Bookmarks Bar") {
        case "other", "synced": rootSpecifier = "other bookmarks"
        default:                rootSpecifier = "bookmarks bar"
        }
        var lines = ["tell application \"Google Chrome\"", "set targetFolder to \(rootSpecifier)"]
        for sub in folderPath.dropFirst() {
            let name = escape(sub)
            lines.append("set matches to (bookmark folders of targetFolder whose title is \"\(name)\")")
            lines.append("if (count of matches) > 0 then")
            lines.append("set targetFolder to item 1 of matches")
            lines.append("else")
            lines.append("set targetFolder to (make new bookmark folder at end of bookmark folders of targetFolder with properties {title:\"\(name)\"})")
            lines.append("end if")
        }
        lines.append("make new bookmark item at end of bookmark items of targetFolder with properties {title:\"\(escape(title))\", URL:\"\(escape(url))\"}")
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    private static func runAppleScript(_ source: String) throws {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw DestinationError.scriptFailed("Couldn't construct the Chrome bookmark script.")
        }
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo["NSAppleScriptErrorMessage"] as? String ?? "Chrome bookmark script failed."
            throw DestinationError.scriptFailed(message)
        }
    }

    /// Escapes a value for an AppleScript double-quoted string (mirrors the
    /// Apple Notes client's escaping).
    static func escape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
           .replacingOccurrences(of: "\n", with: " ")
           .replacingOccurrences(of: "\r", with: " ")
    }
}
