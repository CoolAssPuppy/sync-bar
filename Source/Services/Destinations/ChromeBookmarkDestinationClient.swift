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

    /// Test seams: point at a temp Bookmarks file and force the Chrome-running
    /// state. nil in production (resolve the real profile path / NSRunningApplication).
    var bookmarksURLOverride: URL? = nil
    var chromeRunningOverride: Bool? = nil

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

        // Robust path requires Chrome quit. (B4: AppleScript when running.)
        if chromeRunningOverride ?? Self.isChromeRunning() {
            throw DestinationError.fileSystem("Quit Google Chrome to sync bookmarks — it'll apply next time Chrome is closed.")
        }

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
}
