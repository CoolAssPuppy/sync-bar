//
//  RemarkableRenderer.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation
import CoreGraphics
import AppKit

/// Rasterizes parsed reMarkable strokes into a PNG suitable for OCR: black
/// strokes on a white background, grayscale (OCR doesn't need color).
///
/// The image is fit to the strokes' own bounding box rather than a fixed device
/// canvas. Different reMarkable models use different coordinate systems — the
/// Paper Pro line centers the origin, so y goes negative — and a fixed canvas
/// pushed that content off-screen, yielding a blank image. Fitting the bounding
/// box is device-agnostic and, as a bonus, makes the handwriting fill the frame
/// so OCR reads it more reliably.
enum RemarkableRenderer {

    /// A pure mapping from file coordinates to bottom-left-origin pixels, sized
    /// so the strokes fill `maxDimension` on their longer side (aspect ratio
    /// preserved). Kept separate from drawing so the geometry is testable.
    struct Layout {
        let width: Int
        let height: Int
        let scale: CGFloat
        let minX: CGFloat
        let maxY: CGFloat
        let padding: CGFloat

        /// Maps a file point into the output image. y is flipped (reMarkable y
        /// increases downward; CGContext's origin is bottom-left).
        func map(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - minX + padding) * scale,
                    y: (maxY - point.y + padding) * scale)
        }
    }

    static func layout(for strokes: [[CGPoint]], maxDimension: CGFloat = 2048) -> Layout? {
        let points = strokes.filter { $0.count >= 2 }.flatMap { $0 }
        guard let first = points.first else { return nil }

        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }

        let contentWidth = max(maxX - minX, 1)
        let contentHeight = max(maxY - minY, 1)
        let padding = 0.04 * max(contentWidth, contentHeight)
        let span = max(contentWidth, contentHeight) + 2 * padding
        let scale = max(maxDimension / span, 0.0001)
        let width = Int((contentWidth + 2 * padding) * scale)
        let height = Int((contentHeight + 2 * padding) * scale)
        guard width > 0, height > 0 else { return nil }

        return Layout(width: width, height: height, scale: scale, minX: minX, maxY: maxY, padding: padding)
    }

    static func pngData(for drawing: RemarkableDrawing) -> Data? {
        let strokes = drawing.strokes.filter { $0.count >= 2 }
        guard let layout = layout(for: strokes) else { return nil }

        guard let context = CGContext(
            data: nil,
            width: layout.width,
            height: layout.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: layout.width, height: layout.height))
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(max(2, layout.scale * 1.6))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for stroke in strokes {
            context.beginPath()
            for (index, point) in stroke.enumerated() {
                let mapped = layout.map(point)
                if index == 0 { context.move(to: mapped) } else { context.addLine(to: mapped) }
            }
            context.strokePath()
        }

        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
