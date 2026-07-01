//
//  MarkdownDestinationClient.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// Writes one Markdown file per transcribed page into a user-chosen
/// folder. The mermaid diagram, if present, is appended as a fenced code
/// block so editors like Obsidian, Bear, and iA Writer render it natively.
struct MarkdownDestinationClient: DestinationClient {
    let kind: DestinationKind = .markdownFolder

    func write(payload: DestinationPayload, configuration: DestinationConfiguration, existingExternalId: String?) async throws -> DestinationWriteResult {
        guard case .markdownFolder(let config) = configuration else {
            throw DestinationError.wrongConfiguration(expected: .markdownFolder)
        }
        let folderUrl = URL(fileURLWithPath: config.folderPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folderUrl, withIntermediateDirectories: true)
        } catch {
            throw DestinationError.fileSystem("Couldn't create folder \(folderUrl.path): \(error.localizedDescription)")
        }

        // Update in place: if we wrote this note before, overwrite that exact
        // file so an edit (even one that changes the templated name) updates the
        // original rather than leaving an orphan and writing a new file.
        let relativePath = Self.resolveRelativePath(template: config.fileNameTemplate, payload: payload)
        let fileUrl: URL
        if let existingExternalId, !existingExternalId.isEmpty {
            fileUrl = URL(fileURLWithPath: existingExternalId)
        } else {
            fileUrl = folderUrl.appendingPathComponent(relativePath)
        }

        // A template like "{folder_name}/{date}-{title}" puts the file in a
        // subfolder, so create the file's parent directory (not just the base).
        let parentUrl = fileUrl.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parentUrl, withIntermediateDirectories: true)
        } catch {
            throw DestinationError.fileSystem("Couldn't create folder \(parentUrl.path): \(error.localizedDescription)")
        }

        let frontmatter = Self.frontmatter(payload: payload, mode: config.effectiveFrontmatter)
        let mermaidBlock = payload.mermaidSource.map { "\n\n```mermaid\n\($0)\n```\n" } ?? ""
        let body = "\(frontmatter)# \(payload.title)\n\n\(payload.body)\(mermaidBlock)"

        do {
            try body.write(to: fileUrl, atomically: true, encoding: .utf8)
        } catch {
            throw DestinationError.fileSystem("Couldn't write \(fileUrl.path): \(error.localizedDescription)")
        }
        // Stamp the file with the note's date (the configured date column, e.g.
        // the original pre-migration date) so Finder/Obsidian sort chronologically,
        // mirroring the Python backup's SetFile step. Best-effort: a failure here
        // doesn't fail the write.
        try? FileManager.default.setAttributes(
            [.creationDate: payload.sourceDate, .modificationDate: payload.sourceDate],
            ofItemAtPath: fileUrl.path)
        return DestinationWriteResult(
            externalId: fileUrl.path,
            externalURL: fileUrl,
            notes: "Wrote \(fileUrl.lastPathComponent)"
        )
    }

    // MARK: Helpers

    /// Resolves the template into a relative path (with ".md") under the base
    /// folder. The item's `folderPath` (a Notion Category) becomes a leading
    /// subfolder, so a database fans out across folders the way the Python backup
    /// does. A "/" in the template makes further subfolders; each component is
    /// independently sanitized.
    ///
    /// The template is split on "/" *before* tokens are substituted, so only a
    /// literal separator in the template creates a subfolder. A "/" that arrives
    /// through a token value (e.g. a note titled "Jess/Prashant") is sanitized
    /// into the file name instead of silently spawning a directory.
    static func resolveRelativePath(template: String, payload: DestinationPayload) -> String {
        let context = TitleTemplateContext(
            notebook: payload.ruleNotebookName,
            pageNumber: payload.pageNumber,
            date: payload.sourceDate,
            title: payload.title,
            folderName: payload.folderName
        )
        let categoryComponents = payload.folderPath.map { sanitizeComponent($0) }
        let templateComponents = (template.isEmpty ? "{notebook}" : template)
            .components(separatedBy: "/")
            .map { sanitizeComponent(context.apply(to: $0)) }
        let components = (categoryComponents + templateComponents)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        let relative = components.isEmpty ? "note" : components.joined(separator: "/")
        return relative + ".md"
    }

    /// YAML frontmatter for the file. `essential` writes the identity/date fields;
    /// `all` adds every source column value; `none` writes nothing. The `notion_id`
    /// is what lets a later run adopt this file instead of duplicating it. For a
    /// reMarkable source (no `sourceId`) it falls back to the original notebook/page
    /// fields so those files keep their shape.
    static func frontmatter(payload: DestinationPayload, mode: FrontmatterMode) -> String {
        guard mode != .none else { return "" }
        let iso = ISO8601DateFormatter()
        var lines: [String] = ["---", "title: \"\(escape(payload.title))\""]

        if !payload.sourceId.isEmpty {
            lines.append("notion_id: \(payload.sourceId)")
            if let category = payload.folderPath.last { lines.append("category: \"\(escape(category))\"") }
            lines.append("created: \(iso.string(from: payload.sourceDate))")
            if let lastEdited = payload.metadata["last_edited"] { lines.append("last_edited: \(lastEdited)") }
        } else {
            // reMarkable-shaped file.
            lines.append("source: reMarkable")
            lines.append("notebook: \"\(escape(payload.ruleNotebookName))\"")
            lines.append("page: \(payload.pageNumber)")
            lines.append("captured_at: \(iso.string(from: payload.sourceDate))")
            if let provider = payload.ocrProvider { lines.append("ocr_provider: \(provider)") }
        }

        if mode == .all {
            // Every other source column value, stable-ordered, skipping ones already
            // emitted above and the internal `last_edited` carrier.
            let shown: Set<String> = ["last_edited"]
            for key in payload.metadata.keys.sorted() where !shown.contains(key) {
                guard let value = payload.metadata[key], !value.isEmpty else { continue }
                lines.append("\(yamlKey(key)): \"\(escape(value))\"")
            }
        }
        if payload.mermaidSource != nil { lines.append("has_diagram: true") }
        lines.append("---\n\n")
        return lines.joined(separator: "\n")
    }

    /// A column name made safe as a YAML key (quote-free, no leading/trailing junk).
    private static func yamlKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.contains(":") || trimmed.contains("\"") ? "\"\(escape(trimmed))\"" : trimmed
    }

    /// Sanitizes a single path component. Keeps "/" out (the caller splits on it
    /// to build subfolders) and trims whitespace so a token expanding to ""
    /// doesn't leave a stray separator or a space-padded folder name.
    private static func sanitizeComponent(_ raw: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:?*\"<>|")
        return raw
            .components(separatedBy: disallowed)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func escape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
