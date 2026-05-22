//
//  NoteBlock.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// One structural element of a transcribed note. A note is an ordered list of
/// these. Blocks come from two sources that share the same shape: reMarkable
/// typed text (parsed structurally, so the paragraph style is exact) and OCR of
/// handwriting (where checkboxes are inferred from `- [ ]` / `- [x]` markers the
/// vision model is asked to emit). Every destination renders blocks its own way
/// — Notion as native block types, Markdown/Linear as task-list markdown, etc.
enum NoteBlock: Equatable, Sendable {
    case heading(String)
    case paragraph(String)
    case bullet(String)
    case checkbox(text: String, checked: Bool)
    case mermaid(String)

    /// True for the two list-style cases, used to keep adjacent list items
    /// tightly spaced when flattening to markdown.
    var isListItem: Bool {
        switch self {
        case .bullet, .checkbox: return true
        case .heading, .paragraph, .mermaid: return false
        }
    }

    var isMermaid: Bool {
        if case .mermaid = self { return true }
        return false
    }

    /// The human-readable text of the block, with no markdown markers. `nil`
    /// for diagrams (a Mermaid source isn't note prose). Used for title
    /// derivation and emptiness checks.
    var plainText: String? {
        switch self {
        case .heading(let text), .paragraph(let text), .bullet(let text):
            return text
        case .checkbox(let text, _):
            return text
        case .mermaid:
            return nil
        }
    }

    /// The block rendered as markdown. Headings use `##` because the note title
    /// already occupies the top-level `#` in destinations that prepend it.
    var markdown: String {
        switch self {
        case .heading(let text):
            return "## \(text)"
        case .paragraph(let text):
            return text
        case .bullet(let text):
            return "- \(text)"
        case .checkbox(let text, let checked):
            return "- [\(checked ? "x" : " ")] \(text)"
        case .mermaid(let source):
            return "```mermaid\n\(source)\n```"
        }
    }
}

/// One note-worth of transcribed content: the ordered blocks plus the OCR
/// provenance and the flattened string forms that the rest of the pipeline and
/// the simpler destinations consume. Built once per note and fanned out to
/// every binding.
struct NoteContent: Equatable, Sendable {
    var blocks: [NoteBlock]
    var provider: String?
    var model: String?

    init(blocks: [NoteBlock], provider: String? = nil, model: String? = nil) {
        self.blocks = blocks
        self.provider = provider
        self.model = model
    }

    var isEmpty: Bool { blocks.isEmpty }

    /// Block texts joined by newlines, no markdown markers. The first line is
    /// what `TitleStrategy.firstLineOfOcr` uses; the whole thing stands in for
    /// the old OCR text in rule evaluation.
    var plainText: String {
        blocks.compactMap(\.plainText).joined(separator: "\n")
    }

    /// All blocks except diagrams, flattened to markdown. Adjacent list items
    /// stay on consecutive lines; everything else is separated by a blank line.
    /// Diagrams are carried separately in `firstMermaid` so destinations that
    /// special-case Mermaid don't render it twice.
    var markdownBody: String {
        let rendered = blocks.filter { !$0.isMermaid }
        var result = ""
        for (index, block) in rendered.enumerated() {
            if index > 0 {
                let tight = block.isListItem && rendered[index - 1].isListItem
                result += tight ? "\n" : "\n\n"
            }
            result += block.markdown
        }
        return result
    }

    /// Every Mermaid diagram on the note, joined into one source, matching the
    /// pre-blocks `OcrResult.mermaidSource` contract. `nil` when there are none.
    var firstMermaid: String? {
        let sources: [String] = blocks.compactMap { block in
            if case .mermaid(let source) = block { return source }
            return nil
        }
        return sources.isEmpty ? nil : sources.joined(separator: "\n\n")
    }
}
