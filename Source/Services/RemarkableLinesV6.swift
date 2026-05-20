//
//  RemarkableLinesV6.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Parser for the reMarkable ".lines" v6 page format. A file is a 43-byte
//  ASCII header followed by length-prefixed blocks; line (stroke) blocks carry
//  the points we rasterize for OCR. The low-level reader and block-envelope
//  walking are unit-tested; the per-field stroke extraction follows the
//  reverse-engineered v6 layout and is expected to need refinement against
//  real device files (we cannot validate it without hardware).
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
        let header = String(decoding: data.prefix(headerLength), as: UTF8.self)
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
        // Walk the length-prefixed block envelope. Each block:
        //   uint32 payloadLength | u8 unknown | u8 minVersion | u8 currentVersion
        //   | u8 blockType | <payload>
        while reader.remaining > 5 {
            let payloadLength: Int
            do { payloadLength = Int(try reader.readUInt32LE()) } catch { break }
            guard payloadLength >= 0, payloadLength <= reader.remaining - 4 else { break }
            _ = try? reader.readUInt8()                 // unknown
            _ = try? reader.readUInt8()                 // min version
            _ = try? reader.readUInt8()                 // current version
            let blockType = (try? reader.readUInt8()) ?? 0xFF
            let payload = (try? reader.readBytes(payloadLength)) ?? []

            // 0x05 == SceneLineItemBlock in the v6 layout.
            if blockType == 0x05, let points = try? extractPoints(fromLineBlock: payload), points.count >= 2 {
                strokes.append(points)
            }
        }
        return RemarkableDrawing(strokes: strokes)
    }

    /// Best-effort extraction of a stroke's points from a line block payload.
    /// v6 stores each point as six little-endian float32s
    /// (x, y, speed, direction, width, pressure); we keep x and y. The block
    /// header fields before the point run vary, so we locate the densest
    /// 24-byte-aligned float run and treat it as the point list. This heuristic
    /// is the piece most likely to need adjustment once real files are available.
    static func extractPoints(fromLineBlock payload: [UInt8]) throws -> [CGPoint] {
        let pointStride = 24  // 6 float32s
        guard payload.count >= pointStride else { return [] }

        var best: [CGPoint] = []
        // Try each alignment offset; pick the longest plausible run of points
        // whose coordinates fall inside the (generous) canvas bounds.
        for start in 0..<pointStride {
            var reader = BinaryReader(bytes: Array(payload[start...]))
            var run: [CGPoint] = []
            while reader.remaining >= pointStride {
                guard let x = try? reader.readFloat32LE(),
                      let y = try? reader.readFloat32LE() else { break }
                _ = try? reader.skip(16)  // speed, direction, width, pressure
                if x.isFinite, y.isFinite, abs(x) <= 2200, abs(y) <= 2200 {
                    run.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
                } else {
                    if run.count > best.count { best = run }
                    run = []
                }
            }
            if run.count > best.count { best = run }
        }
        return best
    }
}
