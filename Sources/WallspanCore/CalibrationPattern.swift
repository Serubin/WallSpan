// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit

/// A wallpaper designed to make bezel misalignment obvious.
///
/// Long diagonals are the instrument: vernier acuity resolves a break in collinearity far
/// below one pixel, and a diagonal responds to both axes at once. Drawn in millimetre
/// space through the normal pipeline, so it is subject to the layout being calibrated.
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
        let slope = CGFloat(0.5774)   // tan(30 deg)

        /// Parallel rules snapped to a multiple of `spacing`, so the grid is absolute.
        func addRules(every spacing: CGFloat, vertical: Bool) {
            var v = ((vertical ? unionMM.minX : unionMM.minY) / spacing).rounded(.down) * spacing
            let limit = vertical ? unionMM.maxX : unionMM.maxY
            while v <= limit {
                if vertical {
                    ctx.move(to: CGPoint(x: mmX(v), y: 0))
                    ctx.addLine(to: CGPoint(x: mmX(v), y: CGFloat(h)))
                } else {
                    ctx.move(to: CGPoint(x: 0, y: mmY(v)))
                    ctx.addLine(to: CGPoint(x: CGFloat(w), y: mmY(v)))
                }
                v += spacing
            }
        }

        /// Both axes in one stroke; two would double-composite every crossing.
        func grid(every spacing: CGFloat, width: CGFloat, color: CGColor) {
            ctx.setLineWidth(line(width))
            ctx.setStrokeColor(color)
            addRules(every: spacing, vertical: true)
            addRules(every: spacing, vertical: false)
            ctx.strokePath()
        }

        func rules(every spacing: CGFloat, vertical: Bool, width: CGFloat, color: CGColor) {
            ctx.setLineWidth(line(width))
            ctx.setStrokeColor(color)
            addRules(every: spacing, vertical: vertical)
            ctx.strokePath()
        }

        let run = unionMM.height / slope
        let diagonalSpacing: CGFloat = 120

        /// Where the diagonals cross and the rings are centred: the 50 mm multiple nearest
        /// the union's middle, so the whole pattern shares the grid's lattice. The true
        /// centre lands on no grid line, and moves as the panels being measured are nudged.
        let anchor = CGPoint(
            x: min(max((unionMM.midX / 50).rounded() * 50, unionMM.minX), unionMM.maxX),
            y: min(max((unionMM.midY / 50).rounded() * 50, unionMM.minY), unionMM.maxY)
        )

        /// Anchor height as a fraction of the union. The families share a `c` only at 0.5,
        /// hence the separate offsets below.
        let anchorT = unionMM.height > 0 ? (anchor.y - unionMM.minY) / unionMM.height : 0.5

        /// One family of ~30-degree diagonals; `rising` picks which end carries the run.
        /// `c` is the x at the union's bottom edge, or its top edge when falling.
        func diagonals(rising: Bool, width: CGFloat, color: CGColor) {
            ctx.setLineWidth(line(width))
            ctx.setStrokeColor(color)

            // Phased so one crossing lands on the anchor.
            let onAnchor = rising
                ? anchor.x - anchorT * run
                : anchor.x - (1 - anchorT) * run
            // Walk back to the first line that can still touch the union, keeping the phase.
            let back = ((onAnchor - (unionMM.minX - run)) / diagonalSpacing).rounded(.up)
            var c = onAnchor - back * diagonalSpacing

            while c <= unionMM.maxX {
                let (bottom, top) = rising ? (c, c + run) : (c + run, c)
                ctx.move(to: CGPoint(x: mmX(bottom), y: mmY(unionMM.minY)))
                ctx.addLine(to: CGPoint(x: mmX(top), y: mmY(unionMM.maxY)))
                c += diagonalSpacing
            }
            ctx.strokePath()
        }

        ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // 10 mm grid, faint — gives an absolute scale reference across both panels.
        grid(every: 10, width: 0.25, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.13))

        // 100 mm majors, brighter.
        grid(every: 100, width: 0.5, color: CGColor(srgbRed: 0.4, green: 0.8, blue: 1, alpha: 0.38))

        // The instrument: diagonals at 120 mm. Crossings break into an X on error.
        diagonals(rising: true, width: 1.2,
                  color: CGColor(srgbRed: 1, green: 0.85, blue: 0.2, alpha: 0.95))
        diagonals(rising: false, width: 0.8,
                  color: CGColor(srgbRed: 0.2, green: 1, blue: 0.75, alpha: 0.75))

        // Horizontal rules isolate pure vertical error: they break into visible steps.
        rules(every: 50, vertical: false, width: 1.0,
              color: CGColor(srgbRed: 1, green: 0.35, blue: 0.45, alpha: 0.9))

        // Concentric rings on the anchor: a circle crossing a seam is unforgiving. 50 mm
        // radii off a 50 mm anchor keep every ring meeting the rules and the grid.
        ctx.setLineWidth(line(0.9))
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.8))
        let cx = mmX(anchor.x), cy = mmY(anchor.y)
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
