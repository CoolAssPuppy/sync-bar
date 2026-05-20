//
//  RemarkableRenderer.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation
import CoreGraphics
import AppKit

/// Rasterizes a parsed reMarkable page into a PNG suitable for OCR: black
/// strokes on a white background, grayscale (OCR doesn't need color).
enum RemarkableRenderer {

    static func pngData(for drawing: RemarkableDrawing, scale: CGFloat = 1.0) -> Data? {
        guard !drawing.isEmpty else { return nil }

        let canvas = RemarkableDrawing.canvasSize
        let width = Int(canvas.width * scale)
        let height = Int(canvas.height * scale)
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(max(1, 2 * scale))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // File coordinates put x centered at 0 and y increasing downward; the
        // CGContext origin is bottom-left, so center x and flip y.
        let offsetX = canvas.width / 2
        for stroke in drawing.strokes where stroke.count >= 2 {
            context.beginPath()
            for (index, point) in stroke.enumerated() {
                let mapped = CGPoint(
                    x: (point.x + offsetX) * scale,
                    y: (canvas.height - point.y) * scale
                )
                if index == 0 { context.move(to: mapped) } else { context.addLine(to: mapped) }
            }
            context.strokePath()
        }

        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
