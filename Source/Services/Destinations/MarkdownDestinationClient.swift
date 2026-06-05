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

        let frontmatter = config.includeFrontmatter ? Self.frontmatter(payload: payload) : ""
        let mermaidBlock = payload.mermaidSource.map { "\n\n```mermaid\n\($0)\n```\n" } ?? ""
        let body = "\(frontmatter)# \(payload.title)\n\n\(payload.body)\(mermaidBlock)"

        do {
            try body.write(to: fileUrl, atomically: true, encoding: .utf8)
        } catch {
            throw DestinationError.fileSystem("Couldn't write \(fileUrl.path): \(error.localizedDescription)")
        }
        return DestinationWriteResult(
            externalId: fileUrl.path,
            externalURL: fileUrl,
            notes: "Wrote \(fileUrl.lastPathComponent)"
        )
    }

    // MARK: Helpers

    /// Resolves the template into a relative path (with ".md") under the base
    /// folder. A "/" in the template makes a subfolder, so the slash is kept as
    /// a separator while each path component is independently sanitized.
    private static func resolveRelativePath(template: String, payload: DestinationPayload) -> String {
        let context = TitleTemplateContext(
            notebook: payload.ruleNotebookName,
            pageNumber: payload.pageNumber,
            date: payload.sourceDate,
            title: payload.title,
            folderName: payload.folderName
        )
        let resolved = context.apply(to: template.isEmpty ? "{notebook}" : template)
        let components = resolved
            .components(separatedBy: "/")
            .map { sanitizeComponent($0) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        let relative = components.isEmpty ? "note" : components.joined(separator: "/")
        return relative + ".md"
    }

    private static func frontmatter(payload: DestinationPayload) -> String {
        let dateFormatter = ISO8601DateFormatter()
        var lines: [String] = ["---", "title: \"\(escape(payload.title))\"",
                               "source: reMarkable",
                               "notebook: \"\(escape(payload.ruleNotebookName))\"",
                               "page: \(payload.pageNumber)",
                               "captured_at: \(dateFormatter.string(from: payload.sourceDate))"]
        if let provider = payload.ocrProvider { lines.append("ocr_provider: \(provider)") }
        if payload.mermaidSource != nil { lines.append("has_diagram: true") }
        lines.append("---\n\n")
        return lines.joined(separator: "\n")
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
