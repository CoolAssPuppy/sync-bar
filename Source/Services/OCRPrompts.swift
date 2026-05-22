//
//  OCRPrompts.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Tweak these prompts to change OCR behavior. Vision uses no prompt at all
//  (the framework returns recognized text). OpenAI and Anthropic vision
//  endpoints use the text in `Self.systemPrompt` plus the page image.
//

import Foundation

/// Central tweak point for everything we tell the OCR model.
///
/// The transcription prompt has two jobs:
///   1. Extract clean plain text from the page.
///   2. When the page is a diagram with no text body, return a Mermaid
///      diagram describing what it sees. We rely on a `<mermaid>...</mermaid>`
///      sentinel so the rule engine can split the output and write the
///      diagram into its own code block in the destination doc.
enum OCRPrompts {

    /// The instructional prompt sent to OpenAI and Anthropic vision endpoints.
    /// Keep this short, specific, and unambiguous — the model follows it
    /// best when it sounds like a checklist, not a paragraph.
    static let systemPrompt: String = """
    You transcribe a single page from a reMarkable tablet. Output plain text only.

    Rules:
    1. Preserve line breaks exactly as written. No extra blank lines.
    2. Spell out abbreviations only when context makes them clear.
    3. If a word is unreadable, write [?] in its place.
    4. If the page is empty, output exactly: [blank page]
    5. If a line has a hand-drawn checkbox — a small empty square, box, or \
    circle to the left of a short line of text — transcribe it as a Markdown \
    task item: `- [ ]` when the box is empty, or `- [x]` when it is ticked, \
    crossed out, or filled. Only do this for clear checkbox marks; leave \
    ordinary dashes and bullets as plain text.
    6. If the page is a sketch or diagram (boxes, arrows, flow, hierarchy, \
    sequence, or relationships) with little or no prose, do NOT describe it in \
    English. Instead output a single Mermaid diagram wrapped in sentinels:
       <mermaid>
       (mermaid source here)
       </mermaid>
       Reproduce the diagram FAITHFULLY, not a tidied-up version:
       - Include every node, using its exact handwritten label text (verbatim; \
    use [?] for an unreadable word). Do not merge, drop, or rename nodes.
       - Include every connector, with the correct direction the arrowhead \
    shows. If a line has no arrowhead, use an undirected link.
       - Put any text written on or beside an arrow as that edge's label.
       - Keep the spatial structure (top-to-bottom vs left-to-right, branches, \
    groupings) as drawn.
       - Do NOT invent nodes, edges, or connections the page doesn't show. If a \
    connection is ambiguous, include it as a plain link rather than guessing.
       Pick the diagram type that matches what's drawn: `flowchart TD` (or `LR`), \
    `sequenceDiagram`, `classDiagram`, `stateDiagram-v2`, `erDiagram`, or \
    `mindmap`. Use short node ids with the real labels in brackets.
    7. If the page mixes prose and a diagram, output the prose first, a blank \
    line, then the `<mermaid>...</mermaid>` block.
    8. Do not add commentary, headings, or any markdown formatting beyond the \
    `- [ ]` / `- [x]` checkbox lines and the mermaid block. Output nothing \
    outside of what you transcribed.
    """

    /// Per-request user message hint. The model sees this alongside the
    /// image. The trailing instruction nudges the model to be terse.
    static let userMessage: String = """
    Transcribe this page following the rules above. Plain text only, except \
    for `- [ ]` / `- [x]` checkbox lines and the optional <mermaid>...</mermaid> block.
    """

    /// Sentinels used by `Self.extractMermaid` to split transcribed text into
    /// (prose, mermaidSource).
    static let mermaidOpen  = "<mermaid>"
    static let mermaidClose = "</mermaid>"

    /// Splits OCR output into the human-readable text portion and an
    /// optional Mermaid diagram block. If no `<mermaid>` sentinel is present,
    /// `mermaidSource` is nil and `text` is the entire input trimmed.
    static func extractMermaid(from raw: String) -> (text: String, mermaidSource: String?) {
        guard let openRange = raw.range(of: Self.mermaidOpen),
              let closeRange = raw.range(of: Self.mermaidClose, range: openRange.upperBound..<raw.endIndex) else {
            return (raw.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        let textPart = raw[..<openRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mermaidPart = raw[openRange.upperBound..<closeRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (textPart, mermaidPart.isEmpty ? nil : mermaidPart)
    }
}
