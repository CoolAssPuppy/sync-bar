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
        let drawing = try RemarkableLinesV6.parse(Data(bytes))

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
        let drawing = try RemarkableLinesV6.parse(Data(bytes))
        XCTAssertEqual(drawing.strokes.count, 2)
    }
}
