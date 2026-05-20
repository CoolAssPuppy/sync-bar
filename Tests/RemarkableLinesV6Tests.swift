//
//  RemarkableLinesV6Tests.swift
//  SyncNerdsTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncNerds

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

    // MARK: Point extraction

    func test_extractPoints_recovers_clean_point_run() throws {
        // Three points; the 16 trailing bytes per point are 0xFF so that any
        // misaligned read lands on NaN and is rejected, leaving the aligned run.
        var payload: [UInt8] = []
        let coords: [(Float, Float)] = [(100, 200), (101, 201), (102, 202)]
        for (x, y) in coords {
            payload += float32LE(x)
            payload += float32LE(y)
            payload += [UInt8](repeating: 0xFF, count: 16)
        }
        let points = try RemarkableLinesV6.extractPoints(fromLineBlock: payload)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(Float(points[0].x), 100)
        XCTAssertEqual(Float(points[0].y), 200)
        XCTAssertEqual(Float(points[2].x), 102)
    }
}
