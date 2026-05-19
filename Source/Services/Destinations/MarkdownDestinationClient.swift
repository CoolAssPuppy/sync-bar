//
//  MarkdownDestinationClient.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// Writes one Markdown file per transcribed page into a user-chosen
/// folder. The mermaid diagram, if present, is appended as a fenced code
/// block so editors like Obsidian, Bear, and iA Writer render it natively.
struct MarkdownDestinationClient: DestinationClient {
    let kind: DestinationKind = .markdownFolder

    func write(payload: DestinationPayload, configuration: DestinationConfiguration) async throws -> DestinationWriteResult {
        guard case .markdownFolder(let config) = configuration else {
            throw OcrError.providerRefused("Markdown binding has wrong configuration.")
        }
        let folderUrl = URL(fileURLWithPath: config.folderPath, isDirectory: true)
        try FileManager.default.createDirectory(at: folderUrl, withIntermediateDirectories: true)

        let fileName = Self.resolveFileName(template: config.fileNameTemplate, payload: payload) + ".md"
        let fileUrl = folderUrl.appendingPathComponent(fileName)

        let frontmatter = config.includeFrontmatter ? Self.frontmatter(payload: payload) : ""
        let mermaidBlock = payload.mermaidSource.map { "\n\n```mermaid\n\($0)\n```\n" } ?? ""
        let body = "\(frontmatter)# \(payload.title)\n\n\(payload.body)\(mermaidBlock)"

        try body.write(to: fileUrl, atomically: true, encoding: .utf8)
        return DestinationWriteResult(
            externalId: fileUrl.path,
            externalURL: fileUrl,
            notes: "Wrote \(fileName)"
        )
    }

    // MARK: Helpers

    private static func resolveFileName(template: String, payload: DestinationPayload) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        var out = template.isEmpty ? "{notebook}-page-{page_n}" : template
        out = out.replacingOccurrences(of: "{notebook}", with: payload.ruleNotebookName)
        out = out.replacingOccurrences(of: "{page_n}", with: "\(payload.pageNumber)")
        out = out.replacingOccurrences(of: "{date}", with: dateFormatter.string(from: payload.sourceDate))
        out = out.replacingOccurrences(of: "{title}", with: payload.title)
        return sanitize(out)
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

    private static func sanitize(_ raw: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:?*\"<>|")
        return raw.components(separatedBy: disallowed).joined(separator: "-")
    }

    private static func escape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
