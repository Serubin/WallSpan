// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit

/// A wallpaper designed to make bezel misalignment obvious.
///
/// Long diagonals are the instrument: vernier acuity resolves a break in collinearity well
/// below one pixel, and a diagonal responds to horizontal and vertical error at once.
/// Drawn in millimetre space through the normal pipeline, so what reaches the screen is
/// subject to exactly the layout being calibrated.
public enum CalibrationPattern {
    /// - Parameter unionMM: the physical union being calibrated.
    /// - Parameter pxPerMM: rasterisation density; the pattern is resolution-independent.
    public static func make(unionMM: CGRect, pxPerMM: CGFloat) -> CGImage? {
        let w = Int((unionMM.width * pxPerMM).rounded())
        let h = Int((unionMM.height * pxPerMM).rounded())
        guard w > 0, h > 0, let ctx = SpanRenderer.context(pixelWidth: w, pixelHeight: h)
        else { return nil }

        func mmX(_ v: CGFloat) -> CGFloat { (v - unionMM.minX) * pxPerMM }
        func mmY(_ v: CGFloat) -> CGFloat { (v - unionMM.minY) * pxPerMM }
        func line(_ mm: CGFloat) -> CGFloat { max(1, mm * pxPerMM) }

        ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // 10 mm grid, faint — gives an absolute scale reference across both panels.
        ctx.setLineWidth(line(0.25))
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.13))
        var gx = (unionMM.minX / 10).rounded(.down) * 10
        while gx <= unionMM.maxX {
            ctx.move(to: CGPoint(x: mmX(gx), y: 0)); ctx.addLine(to: CGPoint(x: mmX(gx), y: CGFloat(h)))
            gx += 10
        }
        var gy = (unionMM.minY / 10).rounded(.down) * 10
        while gy <= unionMM.maxY {
            ctx.move(to: CGPoint(x: 0, y: mmY(gy))); ctx.addLine(to: CGPoint(x: CGFloat(w), y: mmY(gy)))
            gy += 10
        }
        ctx.strokePath()

        // 100 mm majors, brighter.
        ctx.setLineWidth(line(0.5))
        ctx.setStrokeColor(CGColor(srgbRed: 0.4, green: 0.8, blue: 1, alpha: 0.38))
        var mx = (unionMM.minX / 100).rounded(.down) * 100
        while mx <= unionMM.maxX {
            ctx.move(to: CGPoint(x: mmX(mx), y: 0)); ctx.addLine(to: CGPoint(x: mmX(mx), y: CGFloat(h)))
            mx += 100
        }
        var my = (unionMM.minY / 100).rounded(.down) * 100
        while my <= unionMM.maxY {
            ctx.move(to: CGPoint(x: 0, y: mmY(my))); ctx.addLine(to: CGPoint(x: CGFloat(w), y: mmY(my)))
            my += 100
        }
        ctx.strokePath()

        // The instrument: long diagonals at ~30 degrees, spaced 120 mm.
        ctx.setLineWidth(line(1.2))
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.2, alpha: 0.95))
        let slope = CGFloat(0.5774)   // tan(30 deg)
        var c = unionMM.minX - unionMM.height / slope
        while c <= unionMM.maxX + unionMM.height {
            ctx.move(to: CGPoint(x: mmX(c), y: mmY(unionMM.minY)))
            ctx.addLine(to: CGPoint(x: mmX(c + unionMM.height / slope), y: mmY(unionMM.maxY)))
            c += 120
        }
        ctx.strokePath()

        // Counter-diagonals: at the crossings, residual error shows as a broken X.
        ctx.setLineWidth(line(0.8))
        ctx.setStrokeColor(CGColor(srgbRed: 0.2, green: 1, blue: 0.75, alpha: 0.75))
        c = unionMM.minX - unionMM.height / slope
        while c <= unionMM.maxX + unionMM.height {
            ctx.move(to: CGPoint(x: mmX(c + unionMM.height / slope), y: mmY(unionMM.minY)))
            ctx.addLine(to: CGPoint(x: mmX(c), y: mmY(unionMM.maxY)))
            c += 120
        }
        ctx.strokePath()

        // Horizontal rules isolate pure vertical error: they break into visible steps.
        ctx.setLineWidth(line(1.0))
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.35, blue: 0.45, alpha: 0.9))
        var hy = (unionMM.minY / 50).rounded(.down) * 50
        while hy <= unionMM.maxY {
            ctx.move(to: CGPoint(x: 0, y: mmY(hy))); ctx.addLine(to: CGPoint(x: CGFloat(w), y: mmY(hy)))
            hy += 50
        }
        ctx.strokePath()

        // Concentric rings centred on the union: a circle crossing a seam is unforgiving.
        ctx.setLineWidth(line(0.9))
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.8))
        let cx = mmX(unionMM.midX), cy = mmY(unionMM.midY)
        var r: CGFloat = 50
        while r < max(unionMM.width, unionMM.height) {
            ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r * pxPerMM,
                       startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.strokePath()
            r += 50
        }
        return ctx.makeImage()
    }
}
