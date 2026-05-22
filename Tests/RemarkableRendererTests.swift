//
//  RemarkableRendererTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
import CoreGraphics
@testable import SyncBar

final class RemarkableRendererTests: XCTestCase {

    /// The Paper Pro line centers its coordinate origin, so y goes negative.
    /// The layout must fit those strokes inside the image rather than mapping
    /// them off a fixed canvas (which produced a blank OCR input).
    func test_layout_fits_negative_coordinates_within_bounds() throws {
        let strokes = [[CGPoint(x: -96, y: -247), CGPoint(x: 706, y: 259)]]
        let layout = try XCTUnwrap(RemarkableRenderer.layout(for: strokes))

        XCTAssertGreaterThan(layout.width, 0)
        XCTAssertGreaterThan(layout.height, 0)
        for stroke in strokes {
            for point in stroke {
                let mapped = layout.map(point)
                XCTAssertGreaterThanOrEqual(mapped.x, 0)
                XCTAssertLessThanOrEqual(mapped.x, CGFloat(layout.width))
                XCTAssertGreaterThanOrEqual(mapped.y, 0)
                XCTAssertLessThanOrEqual(mapped.y, CGFloat(layout.height))
            }
        }
    }

    func test_layout_is_nil_for_no_renderable_strokes() {
        XCTAssertNil(RemarkableRenderer.layout(for: []))
        XCTAssertNil(RemarkableRenderer.layout(for: [[CGPoint(x: 0, y: 0)]]))  // single point < 2
    }

    func test_layout_preserves_aspect_ratio() throws {
        // Wide content should yield a wider-than-tall image (no distortion).
        let layout = try XCTUnwrap(RemarkableRenderer.layout(for: [[CGPoint(x: 0, y: 0), CGPoint(x: 1000, y: 100)]]))
        XCTAssertGreaterThan(layout.width, layout.height)
    }
}
