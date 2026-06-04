//
//  CRC32C.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  CRC32C (Castagnoli) checksum. reMarkable blob uploads carry an
//  `x-goog-hash: crc32c=<base64>` header because the cloud is GCS-backed and
//  validates it. This is NOT the zlib/CRC-32 used by gzip — it uses the
//  Castagnoli polynomial (reflected 0x82F63B78). Pure and deterministic;
//  pinned by a known-answer test.
//

import Foundation

enum CRC32C {
    private static let table: [UInt32] = {
        let poly: UInt32 = 0x82F6_3B78   // reflected Castagnoli polynomial
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var crc = UInt32(index)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ poly : (crc >> 1)
            }
            table[index] = crc
        }
        return table
    }()

    /// The CRC32C of `data`.
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let slot = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[slot]
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// The value for the `x-goog-hash` header: `crc32c=<base64 of the four
    /// big-endian checksum bytes>`.
    static func googHashHeader(_ data: Data) -> String {
        var bigEndian = checksum(data).bigEndian
        let bytes = withUnsafeBytes(of: &bigEndian) { Data($0) }
        return "crc32c=" + bytes.base64EncodedString()
    }
}
