//
//  RemarkableLinesV6.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Parser for the reMarkable ".lines" v6 page format. A file is a 43-byte
//  ASCII header followed by length-prefixed blocks; SceneLineItem blocks (type
//  0x05) carry the strokes we rasterize for OCR. Each block uses a tagged
//  field encoding (index + wire type); a stroke's points live in a subblock as
//  14-byte (v2) or 24-byte (v1) records of which we keep x and y. Validated
//  against real device files.
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
struct RemarkableDrawing {
    /// Each stroke is a polyline of points in canvas coordinates.
    var strokes: [[CGPoint]]
    /// reMarkable portrait canvas (points). Origin is top-left; x is centered
    /// around 0 in the file, so the renderer offsets by width/2.
    static let canvasSize = CGSize(width: 1404, height: 1872)

    var isEmpty: Bool { strokes.allSatisfy { $0.count < 2 } }
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

    /// Parses a v6 page into renderable strokes. v3/v5 files are detected and
    /// reported as unsupported (the modern device writes v6).
    static func parse(_ data: Data) throws -> RemarkableDrawing {
        let version = try version(of: data)
        guard version == 6 else { throw ParseError.unsupportedVersion(version) }

        var reader = BinaryReader(data)
        try reader.skip(headerLength)

        var strokes: [[CGPoint]] = []
        // The body is a sequence of blocks. Each block:
        //   uint32 contentLength | u8 unknown | u8 minVersion | u8 currentVersion
        //   | u8 blockType | <contentLength bytes of content>
        // Block type 0x05 is a SceneLineItemBlock carrying one stroke.
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

            if blockType == 0x05,
               let points = try? linePoints(in: content, currentVersion: Int(currentVersion)),
               points.count >= 2 {
                strokes.append(points)
            }
        }
        return RemarkableDrawing(strokes: strokes)
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
}
