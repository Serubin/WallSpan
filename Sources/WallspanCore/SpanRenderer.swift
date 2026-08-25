// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit

public struct RenderedScreen {
    public let display: DisplayInfo
    public let placement: Placement
    public let image: CGImage
}

/// Maps one source image across every display as a single continuous picture.
///
/// The source is aspect-filled into the *physical* union of the panels' active areas and
/// each panel samples the millimetre sub-rect it occupies; content falling in a bezel gap
/// is rendered and discarded. The mm->source mapping is global, so continuity across a
/// seam is exact in physical space even when panels differ in pixel density.
public enum SpanRenderer {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func context(pixelWidth w: Int, pixelHeight h: Int) -> CGContext? {
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        ctx?.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx?.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx
    }

    /// Where the aspect-filled source sits inside the union, in the union's own units.
    /// Shared by render/preview/verify so they cannot drift.
    public static func placement(source: CGSize, union: CGRect) -> CGRect {
        let scale = max(union.width / source.width, union.height / source.height)
        let fitted = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(
            x: union.minX + (union.width - fitted.width) / 2,
            y: union.minY + (union.height - fitted.height) / 2,
            width: fitted.width, height: fitted.height
        )
    }

    /// The rect, in this display's pixel space, into which the whole source is drawn.
    /// `MappingVerifier` inverts this rather than reimplementing it.
    public static func drawRect(
        placedMM: CGRect, display: DisplayInfo, placement p: Placement
    ) -> CGRect {
        let sx = CGFloat(display.pixelWidth) / p.sizeMM.width
        let sy = CGFloat(display.pixelHeight) / p.sizeMM.height
        return CGRect(
            x: (placedMM.minX - p.originMM.x) * sx,
            y: (placedMM.minY - p.originMM.y) * sy,
            width: placedMM.width * sx,
            height: placedMM.height * sy
        )
    }

    /// `debugOffset` (millimetres) deliberately misaligns every display after the first,
    /// so a self-test can prove its metric detects a broken render.
    public static func render(
        source: CGImage, layout: PhysicalLayout, debugOffset: CGPoint = .zero
    ) -> [RenderedScreen] {
        let srcSize = CGSize(width: source.width, height: source.height)
        let placedMM = placement(source: srcSize, union: layout.unionMM)
        let firstUUID = layout.entries.first?.placement.uuid

        return layout.entries.compactMap { entry in
            let (display, p) = (entry.display, entry.placement)
            guard let ctx = context(pixelWidth: display.pixelWidth, pixelHeight: display.pixelHeight)
            else { return nil }
            ctx.interpolationQuality = .high

            var effective = placedMM
            if debugOffset != .zero, p.uuid != firstUUID {
                effective = placedMM.offsetBy(dx: -debugOffset.x, dy: -debugOffset.y)
            }
            ctx.draw(source, in: drawRect(placedMM: effective, display: display, placement: p))

            guard let out = ctx.makeImage() else { return nil }
            return RenderedScreen(display: display, placement: p, image: out)
        }
    }

    /// Renders the physical union with each panel outlined and everything the panels do
    /// not show — bezel gaps included — dimmed.
    public static func renderPreview(
        source: CGImage, layout: PhysicalLayout, maxDimension: CGFloat = 2400
    ) -> CGImage? {
        let union = layout.unionMM
        let k = min(4, maxDimension / max(union.width, union.height))
        let w = Int((union.width * k).rounded()), h = Int((union.height * k).rounded())
        guard w > 0, h > 0, let ctx = context(pixelWidth: w, pixelHeight: h) else { return nil }
        ctx.interpolationQuality = .high

        let placedMM = placement(source: CGSize(width: source.width, height: source.height),
                                 union: union)
        let inPreview = CGRect(
            x: (placedMM.minX - union.minX) * k, y: (placedMM.minY - union.minY) * k,
            width: placedMM.width * k, height: placedMM.height * k
        )
        ctx.draw(source, in: inPreview)

        // Dim everything, then punch the panels back to full brightness.
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.62))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let rects = layout.entries.map { e in
            CGRect(x: (e.placement.originMM.x - union.minX) * k,
                   y: (e.placement.originMM.y - union.minY) * k,
                   width: e.placement.sizeMM.width * k,
                   height: e.placement.sizeMM.height * k)
        }
        ctx.saveGState()
        ctx.clip(to: rects)
        ctx.draw(source, in: inPreview)
        ctx.restoreGState()

        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.2, blue: 0.3, alpha: 0.95))
        ctx.setLineWidth(3)
        for r in rects { ctx.stroke(r) }
        return ctx.makeImage()
    }
}
