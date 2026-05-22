//
//  RemarkableLinesV6.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Parser for the reMarkable ".lines" v6 page format. A file is a 43-byte
//  ASCII header followed by length-prefixed blocks; SceneLineItem blocks (type
//  0x05) carry the strokes we rasterize for OCR, and RootTextBlock (type 0x07)
//  carries typed text — each paragraph stamped with a style (heading, bullet,
//  checkbox, …), which is where reMarkable's 3.8 checklists live. Each block
//  uses a tagged field encoding (index + wire type); a stroke's points live in
//  a subblock as 14-byte (v2) or 24-byte (v1) records of which we keep x and y.
//  The text-block layout mirrors rmscene (scene_stream.py / text.py). Stroke
//  parsing is validated against real device files; text parsing is ported from
//  rmscene and covered by synthetic tests, pending real-device validation.
//

import Foundation
import CoreGraphics

/// A cursor over a byte buffer with the little-endian primitives the v6 format
/// uses. Every read is bounds-checked and throws rather than trapping.
struct BinaryReader {
    enum ReadError: Error { case outOfBounds }

    let bytes: [UInt8]
    private(set) var offset: Int = 0

    init(_ data: Data) { self.bytes = [UInt8](data) }
    init(bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { offset >= bytes.count }
    var remaining: Int { bytes.count - offset }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < bytes.count else { throw ReadError.outOfBounds }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt32LE() throws -> UInt32 {
        guard offset + 4 <= bytes.count else { throw ReadError.outOfBounds }
        defer { offset += 4 }
        return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    mutating func readFloat32LE() throws -> Float {
        Float(bitPattern: try readUInt32LE())
    }

    /// LEB128 unsigned varint, as used for v6 lengths and CRDT ids.
    mutating func readVarUInt() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try readUInt8()
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift > 63 { throw ReadError.outOfBounds }
        }
        return result
    }

    mutating func skip(_ count: Int) throws {
        guard offset + count <= bytes.count, count >= 0 else { throw ReadError.outOfBounds }
        offset += count
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard offset + count <= bytes.count, count >= 0 else { throw ReadError.outOfBounds }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }
}

/// A rasterizable page: strokes in reMarkable canvas coordinates plus the
/// canvas size used to place them.
struct RemarkableDrawing: Sendable {
    /// Each stroke is a polyline of points in canvas coordinates.
    var strokes: [[CGPoint]]
    /// reMarkable portrait canvas (points). Origin is top-left; x is centered
    /// around 0 in the file, so the renderer offsets by width/2.
    static let canvasSize = CGSize(width: 1404, height: 1872)

    var isEmpty: Bool { strokes.allSatisfy { $0.count < 2 } }
}

/// reMarkable typed-text paragraph styles, from the v6 RootTextBlock. Matches
/// rmscene's `ParagraphStyle`; raw values are the on-disk format codes.
enum ParagraphStyle: UInt8, Equatable, Sendable {
    case basic = 0
    case plain = 1
    case heading = 2
    case bold = 3
    case bullet = 4
    case bullet2 = 5
    case checkbox = 6
    case checkboxChecked = 7
}

/// One line of reMarkable typed text together with its paragraph style.
struct TypedParagraph: Equatable, Sendable {
    var style: ParagraphStyle
    var text: String
}

/// The full parse of a v6 page: rasterizable strokes plus any typed text.
struct RemarkablePage: Sendable {
    var drawing: RemarkableDrawing
    var typedText: [TypedParagraph]
}

enum RemarkableLinesV6 {
    enum ParseError: LocalizedError {
        case badHeader
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .badHeader: return "Not a reMarkable .lines file."
            case .unsupportedVersion(let v): return "Unsupported .lines version \(v)."
            }
        }
    }

    static let headerLength = 43
    private static let headerPrefix = "reMarkable .lines file, version="

    /// Reads the one-digit version from the fixed-width ASCII header.
    static func version(of data: Data) throws -> Int {
        guard data.count >= headerLength else { throw ParseError.badHeader }
        let header = String(bytes: data.prefix(headerLength), encoding: .utf8) ?? ""
        guard header.hasPrefix(headerPrefix),
              let versionChar = header.dropFirst(headerPrefix.count).first,
              let version = Int(String(versionChar)) else {
            throw ParseError.badHeader
        }
        return version
    }

    /// Parses a v6 page into renderable strokes plus any typed text. v3/v5
    /// files are detected and reported as unsupported (the modern device writes
    /// v6).
    static func parse(_ data: Data) throws -> RemarkablePage {
        let version = try version(of: data)
        guard version == 6 else { throw ParseError.unsupportedVersion(version) }

        var reader = BinaryReader(data)
        try reader.skip(headerLength)

        var strokes: [[CGPoint]] = []
        var typedText: [TypedParagraph] = []
        // The body is a sequence of blocks. Each block:
        //   uint32 contentLength | u8 unknown | u8 minVersion | u8 currentVersion
        //   | u8 blockType | <contentLength bytes of content>
        // Block type 0x05 is a SceneLineItemBlock carrying one stroke; 0x07 is
        // the RootTextBlock carrying all of the page's typed text.
        while reader.remaining >= 5 {
            let contentLength: Int
            do { contentLength = Int(try reader.readUInt32LE()) } catch { break }
            guard (try? reader.readUInt8()) != nil,            // unknown
                  (try? reader.readUInt8()) != nil,            // min version
                  let currentVersion = try? reader.readUInt8(),
                  let blockType = try? reader.readUInt8() else { break }
            guard contentLength >= 0, contentLength <= reader.remaining else { break }
            let content = (try? reader.readBytes(contentLength)) ?? []
            guard content.count == contentLength else { break }

            switch blockType {
            case 0x05:
                if let points = try? linePoints(in: content, currentVersion: Int(currentVersion)),
                   points.count >= 2 {
                    strokes.append(points)
                }
            case 0x07:
                if let paragraphs = try? parseRootText(in: content) {
                    typedText.append(contentsOf: paragraphs)
                }
            default:
                break
            }
        }
        return RemarkablePage(drawing: RemarkableDrawing(strokes: strokes), typedText: typedText)
    }

    /// Reads a v6 tag: a varint whose high bits are the field index and whose
    /// low nibble is the wire type (0x1 = 1 byte, 0x4 = 4 bytes, 0x8 = 8 bytes,
    /// 0xC = length-prefixed subblock, 0xF = CRDT id).
    private static func readTag(_ reader: inout BinaryReader) throws -> (index: UInt64, type: UInt8) {
        let raw = try reader.readVarUInt()
        return (raw >> 4, UInt8(raw & 0xF))
    }

    /// A CRDT id is a single author byte followed by a varint counter.
    private static func skipCrdtId(_ reader: inout BinaryReader) throws {
        _ = try reader.readUInt8()
        _ = try reader.readVarUInt()
    }

    /// Extracts a stroke's (x, y) points from a SceneLineItemBlock's content.
    /// Layout: parent/item/left/right CRDT ids, a deleted-length int, then a
    /// value subblock holding the line — tool, color, thickness, starting
    /// length, and a points subblock. Points are 14 bytes in the v2 layout
    /// (x f32, y f32, then speed/width/direction/pressure) or 24 bytes in the
    /// older v1 layout; only x and y are needed for rasterization. Validated
    /// against real device files.
    private static func linePoints(in content: [UInt8], currentVersion: Int) throws -> [CGPoint] {
        var reader = BinaryReader(bytes: content)

        for _ in 0..<4 {                          // parent, item, left, right ids
            _ = try readTag(&reader)
            try skipCrdtId(&reader)
        }
        _ = try readTag(&reader)                  // deleted-length tag
        _ = try reader.readUInt32LE()

        let valueTag = try readTag(&reader)       // value subblock (the line)
        guard valueTag.type == 0xC else { return [] }
        let subLength = Int(try reader.readUInt32LE())
        let subEnd = reader.offset + subLength
        _ = try reader.readUInt8()                // item type (0x03 == line)

        var points: [CGPoint] = []
        while reader.offset < subEnd {
            let field = try readTag(&reader)
            switch field.type {
            case 0xC:                             // the points subblock
                let length = Int(try reader.readUInt32LE())
                let pointsEnd = min(reader.offset + length, subEnd)
                let preferred = currentVersion == 1 ? 24 : 14
                let stride = (length % preferred == 0) ? preferred : (length % 24 == 0 ? 24 : 14)
                while reader.offset + 8 <= pointsEnd {
                    let x = try reader.readFloat32LE()
                    let y = try reader.readFloat32LE()
                    points.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
                    let tail = stride - 8
                    if tail > 0 {
                        guard reader.offset + tail <= pointsEnd else { break }
                        try reader.skip(tail)
                    }
                }
                return points                     // points are the only field we keep
            case 0x8: try reader.skip(8)
            case 0x4: try reader.skip(4)
            case 0x1: try reader.skip(1)
            case 0xF: try skipCrdtId(&reader)
            default:  return points               // unknown tag — stop to stay aligned
            }
        }
        return points
    }

    // MARK: RootTextBlock (typed text)

    /// A reMarkable CRDT id: a single author byte plus a varint counter. Used to
    /// key paragraph styles by the character that starts each line.
    private struct CrdtId: Hashable {
        var part1: UInt8
        var part2: UInt64
    }

    /// Reads a length-prefixed subblock tag and returns the absolute offset at
    /// which the subblock ends.
    private static func readSubblock(_ reader: inout BinaryReader) throws -> Int {
        _ = try readTag(&reader)                  // index + Length4 wire type
        let length = Int(try reader.readUInt32LE())
        return reader.offset + length
    }

    /// Reads a bare CRDT id (author byte + varint counter), with no leading tag.
    private static func readCrdtId(_ reader: inout BinaryReader) throws -> CrdtId {
        let author = try reader.readUInt8()
        let counter = try reader.readVarUInt()
        return CrdtId(part1: author, part2: counter)
    }

    /// Reads a tagged CRDT id (a tag followed by the id).
    private static func readTaggedId(_ reader: inout BinaryReader) throws -> CrdtId {
        _ = try readTag(&reader)
        return try readCrdtId(&reader)
    }

    /// Reads a tagged 4-byte unsigned integer.
    private static func readTaggedInt(_ reader: inout BinaryReader) throws -> UInt32 {
        _ = try readTag(&reader)
        return try reader.readUInt32LE()
    }

    /// Advances the reader to a known subblock end, skipping any trailing fields
    /// we don't consume (e.g. inline format codes). Never seeks backwards.
    private static func advance(_ reader: inout BinaryReader, to end: Int) throws {
        if end > reader.offset { try reader.skip(end - reader.offset) }
    }

    /// Decodes a RootTextBlock into ordered paragraphs with their styles. The
    /// layout (block id, nested subblocks of text items and formats, trailing
    /// position/width) mirrors rmscene's `RootTextBlock.from_stream`.
    private static func parseRootText(in content: [UInt8]) throws -> [TypedParagraph] {
        var reader = BinaryReader(bytes: content)
        _ = try readTaggedId(&reader)             // block_id (CrdtId(0,0))
        let outerEnd = try readSubblock(&reader)  // subblock(2): items + formats

        // Text items: subblock(1) -> subblock(1) -> varuint count -> items.
        let itemsOuterEnd = try readSubblock(&reader)
        _ = try readSubblock(&reader)             // inner items subblock
        let itemCount = try reader.readVarUInt()
        guard itemCount <= UInt64(content.count) else { return [] }

        var items: [(id: CrdtId, value: String)] = []
        for _ in 0..<itemCount {
            let itemEnd = try readSubblock(&reader)        // per-item subblock(0)
            let itemId = try readTaggedId(&reader)         // item id
            _ = try readTaggedId(&reader)                  // left id
            _ = try readTaggedId(&reader)                  // right id
            let deletedLength = try readTaggedInt(&reader) // deleted length
            var value = ""
            if reader.offset < itemEnd {
                let strEnd = try readSubblock(&reader)      // value subblock(6)
                let declared = Int(try reader.readVarUInt())
                _ = try reader.readUInt8()                  // is-ascii flag
                let available = max(0, strEnd - reader.offset)
                let bytes = try reader.readBytes(min(declared, available))
                value = String(decoding: bytes, as: UTF8.self)
                try advance(&reader, to: strEnd)
            }
            // Keep only live text runs; deleted runs carry "" and format-only
            // runs carry an int (decoded as ""), so emptiness filters both out.
            if deletedLength == 0 && !value.isEmpty {
                items.append((id: itemId, value: value))
            }
            try advance(&reader, to: itemEnd)
        }
        try advance(&reader, to: itemsOuterEnd)

        // Formatting: subblock(2) -> subblock(1) -> varuint count -> styles.
        var styles: [CrdtId: ParagraphStyle] = [:]
        if reader.offset < outerEnd {
            _ = try readSubblock(&reader)         // formats outer subblock
            _ = try readSubblock(&reader)         // formats inner subblock
            let formatCount = try reader.readVarUInt()
            if formatCount <= UInt64(content.count) {
                for _ in 0..<formatCount {
                    let charId = try readCrdtId(&reader)    // bare id, no tag
                    _ = try readTaggedId(&reader)           // format timestamp
                    let styleEnd = try readSubblock(&reader)
                    _ = try reader.readUInt8()              // marker byte (17)
                    let code = try reader.readUInt8()
                    if let style = ParagraphStyle(rawValue: code) { styles[charId] = style }
                    try advance(&reader, to: styleEnd)
                }
            }
        }

        return reconstructParagraphs(items: items, styles: styles)
    }

    /// Rebuilds lines from CRDT text runs and the per-line style map. Each run's
    /// characters get sequential ids derived from the run's id; the file keys a
    /// paragraph's style by the id of the newline that precedes it (or the
    /// `CrdtId(0,0)` anchor for the first line). Characters are ordered by id,
    /// which is correct for single-author typed notes (the checklist case).
    private static func reconstructParagraphs(items: [(id: CrdtId, value: String)],
                                              styles: [CrdtId: ParagraphStyle]) -> [TypedParagraph] {
        var characters: [(id: CrdtId, char: Character)] = []
        for item in items {
            for (offset, char) in item.value.enumerated() {
                let id = CrdtId(part1: item.id.part1, part2: item.id.part2 + UInt64(offset))
                characters.append((id: id, char: char))
            }
        }
        characters.sort { lhs, rhs in
            lhs.id.part1 != rhs.id.part1 ? lhs.id.part1 < rhs.id.part1 : lhs.id.part2 < rhs.id.part2
        }

        let anchor = CrdtId(part1: 0, part2: 0)
        var paragraphs: [TypedParagraph] = []
        var index = 0
        while index < characters.count {
            var startId = anchor
            if characters[index].char == "\n" {
                startId = characters[index].id    // the newline that opens this line
                index += 1
            }
            var text = ""
            while index < characters.count, characters[index].char != "\n" {
                text.append(characters[index].char)
                index += 1
            }
            let style = styles[startId] ?? .plain
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                paragraphs.append(TypedParagraph(style: style, text: trimmed))
            }
        }
        return paragraphs
    }
}
