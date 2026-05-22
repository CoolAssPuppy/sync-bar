//
//  NoteContentBuilder.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// Turns the two transcription sources — reMarkable typed paragraphs and OCR
/// text — into the shared `NoteBlock` model. Pure and synchronous; the
/// `SyncCoordinator` orchestrates the async OCR calls and feeds results here.
enum NoteContentBuilder {

    /// Maps one reMarkable typed paragraph to its block, preserving the
    /// paragraph style the device recorded. Checkboxes carry their checked
    /// state directly from the style (`checkboxChecked`).
    static func block(from paragraph: TypedParagraph) -> NoteBlock {
        switch paragraph.style {
        case .heading:
            return .heading(paragraph.text)
        case .bullet, .bullet2:
            return .bullet(paragraph.text)
        case .checkbox:
            return .checkbox(text: paragraph.text, checked: false)
        case .checkboxChecked:
            return .checkbox(text: paragraph.text, checked: true)
        case .basic, .plain, .bold:
            return .paragraph(paragraph.text)
        }
    }

    /// Parses OCR output into blocks. Lines the vision model marked as task
    /// items (`- [ ]` / `- [x]`, the convention the prompt asks for and the
    /// form hand-drawn checkboxes are transcribed to) become checkbox blocks;
    /// everything else groups into paragraphs split on blank lines.
    static func blocks(fromOCRText raw: String) -> [NoteBlock] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "[blank page]" else { return [] }

        var blocks: [NoteBlock] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            let text = paragraphLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraphLines.removeAll()
        }

        for line in trimmed.components(separatedBy: "\n") {
            if let checkbox = checkbox(from: line) {
                flushParagraph()
                blocks.append(checkbox)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
            } else {
                paragraphLines.append(line)
            }
        }
        flushParagraph()
        return blocks
    }

    /// Recognizes a markdown task line (`- [ ] text`, `- [x] text`, also with a
    /// `*` bullet), returning a checkbox block or nil. The tick is
    /// case-insensitive; a missing label yields an empty checkbox.
    private static func checkbox(from line: String) -> NoteBlock? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- [") || trimmed.hasPrefix("* ["), trimmed.count >= 5 else { return nil }
        let afterBullet = trimmed.dropFirst(2)            // drop "- " or "* "
        guard afterBullet.count >= 3 else { return nil }
        let chars = Array(afterBullet)
        guard chars[0] == "[", chars[2] == "]" else { return nil }
        let checked: Bool
        switch chars[1] {
        case " ": checked = false
        case "x", "X": checked = true
        default: return nil
        }
        let text = String(chars.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        return .checkbox(text: text, checked: checked)
    }
}
