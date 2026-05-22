//
//  RemarkableLinesV6Tests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

final class RemarkableLinesV6Tests: XCTestCase {

    private func float32LE(_ value: Float) -> [UInt8] {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) }
    }

    // MARK: BinaryReader primitives

    func test_readUInt32LE() throws {
        var reader = BinaryReader(bytes: [0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual(try reader.readUInt32LE(), 0x0403_0201)
    }

    func test_readVarUInt_decodes_leb128() throws {
        var reader = BinaryReader(bytes: [0xAC, 0x02])  // 300
        XCTAssertEqual(try reader.readVarUInt(), 300)
    }

    func test_readFloat32LE_roundtrips() throws {
        var reader = BinaryReader(bytes: float32LE(1.5))
        XCTAssertEqual(try reader.readFloat32LE(), 1.5)
    }

    func test_reads_past_end_throw() {
        var reader = BinaryReader(bytes: [0x00])
        XCTAssertThrowsError(try reader.readUInt32LE())
    }

    // MARK: Header / version

    private func v6Header() -> [UInt8] {
        let header = "reMarkable .lines file, version=6" + String(repeating: " ", count: 10)
        return Array(header.utf8)
    }

    func test_version_reads_from_header() throws {
        XCTAssertEqual(try RemarkableLinesV6.version(of: Data(v6Header())), 6)
    }

    func test_parse_rejects_non_v6() {
        let header = "reMarkable .lines file, version=5" + String(repeating: " ", count: 10)
        XCTAssertThrowsError(try RemarkableLinesV6.parse(Data(header.utf8))) { error in
            guard case RemarkableLinesV6.ParseError.unsupportedVersion(5) = error else {
                return XCTFail("expected unsupportedVersion(5), got \(error)")
            }
        }
    }

    func test_parse_rejects_garbage_header() {
        XCTAssertThrowsError(try RemarkableLinesV6.parse(Data("not a lines file".utf8)))
    }

    // MARK: Stroke extraction (v6 tagged blocks)

    private func u32LE(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    private func f64LE(_ value: Double) -> [UInt8] {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) }
    }

    /// Builds one SceneLineItemBlock (type 0x05) with the v2 14-byte point
    /// layout, matching the structure of real device files.
    private func v6LineBlock(points: [(Float, Float)]) -> [UInt8] {
        var pointBytes: [UInt8] = []
        for (x, y) in points {
            pointBytes += float32LE(x)
            pointBytes += float32LE(y)
            pointBytes += [0, 0, 0, 0, 0, 0]   // speed u16, width u16, direction u8, pressure u8
        }
        var line: [UInt8] = [0x03]                                  // item type = line
        line += [0x14] + u32LE(15)                                  // tool (Byte4)
        line += [0x24] + u32LE(0)                                   // color (Byte4)
        line += [0x38] + f64LE(2.0)                                 // thickness (Byte8)
        line += [0x44] + float32LE(0)                               // starting length (Byte4)
        line += [0x5C] + u32LE(UInt32(pointBytes.count)) + pointBytes  // points (Length4)

        var content: [UInt8] = []
        content += [0x1F, 0x00, 0x01]                               // parent id
        content += [0x2F, 0x01, 0x02]                               // item id
        content += [0x3F, 0x00, 0x00]                               // left id
        content += [0x4F, 0x00, 0x00]                               // right id
        content += [0x54] + u32LE(0)                                // deleted length (Byte4)
        content += [0x6C] + u32LE(UInt32(line.count)) + line        // value subblock (Length4)

        var block: [UInt8] = u32LE(UInt32(content.count))
        block += [0x00, 0x01, 0x02, 0x05]                          // unknown, minVer, curVer=2, type=line
        block += content
        return block
    }

    func test_parse_extracts_points_from_line_block() throws {
        var bytes = v6Header()
        bytes += v6LineBlock(points: [(10, 20), (30, 40), (50, 60)])
        let drawing = try RemarkableLinesV6.parse(Data(bytes)).drawing

        XCTAssertEqual(drawing.strokes.count, 1)
        XCTAssertEqual(drawing.strokes.first?.count, 3)
        XCTAssertEqual(Float(drawing.strokes[0][0].x), 10)
        XCTAssertEqual(Float(drawing.strokes[0][0].y), 20)
        XCTAssertEqual(Float(drawing.strokes[0][2].x), 50)
        XCTAssertEqual(Float(drawing.strokes[0][2].y), 60)
        XCTAssertFalse(drawing.isEmpty)
    }

    func test_parse_collects_multiple_strokes() throws {
        var bytes = v6Header()
        bytes += v6LineBlock(points: [(1, 2), (3, 4)])
        bytes += v6LineBlock(points: [(5, 6), (7, 8)])
        let drawing = try RemarkableLinesV6.parse(Data(bytes)).drawing
        XCTAssertEqual(drawing.strokes.count, 2)
    }

    // MARK: Typed text extraction (v6 RootTextBlock)

    private func varuint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            out.append(byte)
        } while remaining != 0
        return out
    }

    /// Tag byte: high bits are the field index, low nibble is the wire type.
    private func tag(_ index: UInt8, _ type: UInt8) -> [UInt8] { [(index << 4) | type] }
    private func taggedId(_ index: UInt8, _ author: UInt8, _ counter: UInt64) -> [UInt8] {
        tag(index, 0xF) + [author] + varuint(counter)
    }
    private func taggedInt(_ index: UInt8, _ value: UInt32) -> [UInt8] { tag(index, 0x4) + u32LE(value) }
    private func subblock(_ index: UInt8, _ payload: [UInt8]) -> [UInt8] {
        tag(index, 0xC) + u32LE(UInt32(payload.count)) + payload
    }

    /// A paragraph style entry for `v6TextBlock`: the (author, counter) char id
    /// the style is keyed by, and the on-disk format code.
    private struct StyleEntry {
        let author: UInt8
        let counter: UInt64
        let code: UInt8
    }

    /// Builds a RootTextBlock (type 0x07): the whole `text` as one CRDT run with
    /// id (1,1), plus a styles map keyed by (author, counter) char ids. The
    /// first line is keyed by the (0,0) anchor; later lines by the id of the
    /// newline that opens them.
    private func v6TextBlock(text: String, styles: [StyleEntry]) -> [UInt8] {
        // One text run holding the entire string, starting at char id (1,1).
        let utf8 = Array(text.utf8)
        let valuePayload = varuint(UInt64(utf8.count)) + [1] + utf8
        var itemInner: [UInt8] = []
        itemInner += taggedId(2, 1, 1)        // item id
        itemInner += taggedId(3, 0, 0)        // left id
        itemInner += taggedId(4, 0, 0)        // right id
        itemInner += taggedInt(5, 0)          // deleted length
        itemInner += subblock(6, valuePayload)
        let itemsInner = subblock(1, varuint(1) + subblock(0, itemInner))
        let itemsOuter = subblock(1, itemsInner)

        var formatsList: [UInt8] = varuint(UInt64(styles.count))
        for style in styles {
            formatsList += [style.author] + varuint(style.counter)  // bare char id
            formatsList += taggedId(1, 0, 0)                         // timestamp
            formatsList += subblock(2, [17, style.code])
        }
        let formatsOuter = subblock(2, subblock(1, formatsList))

        let content = taggedId(1, 0, 0) + subblock(2, itemsOuter + formatsOuter)
        return u32LE(UInt32(content.count)) + [0x00, 0x00, 0x01, 0x07] + content
    }

    func test_parse_extracts_typed_paragraphs_with_styles() throws {
        var bytes = v6Header()
        // "Shopping" heading, two checkboxes (one checked), one bullet.
        let text = "Shopping\nBuy milk\nGot eggs\na bullet"
        bytes += v6TextBlock(text: text, styles: [
            StyleEntry(author: 0, counter: 0,  code: ParagraphStyle.heading.rawValue),          // first line
            StyleEntry(author: 1, counter: 9,  code: ParagraphStyle.checkbox.rawValue),         // "Buy milk"
            StyleEntry(author: 1, counter: 18, code: ParagraphStyle.checkboxChecked.rawValue),  // "Got eggs"
            StyleEntry(author: 1, counter: 27, code: ParagraphStyle.bullet.rawValue)            // "a bullet"
        ])

        let typedText = try RemarkableLinesV6.parse(Data(bytes)).typedText
        XCTAssertEqual(typedText, [
            TypedParagraph(style: .heading, text: "Shopping"),
            TypedParagraph(style: .checkbox, text: "Buy milk"),
            TypedParagraph(style: .checkboxChecked, text: "Got eggs"),
            TypedParagraph(style: .bullet, text: "a bullet")
        ])
    }

    func test_lines_without_a_style_default_to_plain() throws {
        var bytes = v6Header()
        bytes += v6TextBlock(text: "just a line", styles: [])
        let typedText = try RemarkableLinesV6.parse(Data(bytes)).typedText
        XCTAssertEqual(typedText, [TypedParagraph(style: .plain, text: "just a line")])
    }

    func test_parse_returns_strokes_and_typed_text_together() throws {
        var bytes = v6Header()
        bytes += v6LineBlock(points: [(1, 2), (3, 4)])
        bytes += v6TextBlock(text: "Task one", styles: [StyleEntry(author: 0, counter: 0, code: ParagraphStyle.checkbox.rawValue)])
        let page = try RemarkableLinesV6.parse(Data(bytes))
        XCTAssertEqual(page.drawing.strokes.count, 1)
        XCTAssertEqual(page.typedText, [TypedParagraph(style: .checkbox, text: "Task one")])
    }

    func test_garbage_text_block_yields_no_paragraphs_without_throwing() throws {
        var bytes = v6Header()
        let content: [UInt8] = [0x1F, 0x00, 0x00, 0xFF, 0xFF]  // valid block id, then junk
        bytes += u32LE(UInt32(content.count)) + [0x00, 0x00, 0x01, 0x07] + content
        let page = try RemarkableLinesV6.parse(Data(bytes))
        XCTAssertTrue(page.typedText.isEmpty)
    }

    // MARK: Typed-vs-handwriting ordering

    private func page(strokeYs: [CGFloat], typedTextTopY: Double?) -> RemarkablePage {
        let strokes = strokeYs.isEmpty ? [] : [strokeYs.map { CGPoint(x: 0, y: $0) }]
        return RemarkablePage(drawing: RemarkableDrawing(strokes: strokes), typedText: [], typedTextTopY: typedTextTopY)
    }

    func test_typed_text_below_handwriting_orders_handwriting_first() {
        // Strokes span y -200..0 (center -100); typed box at y 234 is far below.
        XCTAssertFalse(page(strokeYs: [-200, 0], typedTextTopY: 234).typedTextLeadsHandwriting)
    }

    func test_typed_text_above_handwriting_orders_typed_first() {
        // Strokes span y 100..300 (center 200); typed box at y -50 is above them.
        XCTAssertTrue(page(strokeYs: [100, 300], typedTextTopY: -50).typedTextLeadsHandwriting)
    }

    func test_ordering_defaults_to_typed_first_without_position_or_strokes() {
        XCTAssertTrue(page(strokeYs: [], typedTextTopY: 100).typedTextLeadsHandwriting)   // no strokes
        XCTAssertTrue(page(strokeYs: [0, 100], typedTextTopY: nil).typedTextLeadsHandwriting) // no pos
    }
}
