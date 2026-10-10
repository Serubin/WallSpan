// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import CoreGraphics

/// A test pattern designed to make bezel misalignment obvious, drawn in millimetre space.
///
/// Long diagonals are the instrument: vernier acuity resolves a break in collinearity far
/// below one pixel, and a diagonal responds to both axes at once.
public enum CalibrationLattice {
    /// Behind the lattice. Callers choose the opacity: a wallpaper fills it solid.
    public static let backdrop = CGColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)

    /// - Parameter ctx: its CTM must map y-up millimetres to device space.
    /// - Parameter extentMM: how far to draw. Only the anchor phases the lattice, so one
    ///   panel's extent shows exactly what the whole union would there.
    /// - Parameter anchorMM: where the lattice is pinned — see `PhysicalLayout.anchorMM`.
    /// - Parameter minLineMM: one device pixel in millimetres, the thinnest line drawn.
    public static func draw(
        in ctx: CGContext, extentMM: CGRect, anchorMM: CGPoint, minLineMM: CGFloat
    ) {
        func line(_ mm: CGFloat) -> CGFloat { max(minLineMM, mm) }
        let slope = CGFloat(0.5774)   // tan(30 deg)

        // Every line overruns the extent, so none ends inside a panel or misses its edge.
        let span = extentMM.insetBy(dx: -1, dy: -1)

        /// Parallel rules phased on the anchor, so every spacing shares its lattice.
        func addRules(every spacing: CGFloat, vertical: Bool) {
            let a = vertical ? anchorMM.x : anchorMM.y
            let lo = vertical ? span.minX : span.minY
            var v = a + ((lo - a) / spacing).rounded(.down) * spacing
            let limit = vertical ? span.maxX : span.maxY
            while v <= limit {
                if vertical {
                    ctx.move(to: CGPoint(x: v, y: span.minY))
                    ctx.addLine(to: CGPoint(x: v, y: span.maxY))
                } else {
                    ctx.move(to: CGPoint(x: span.minX, y: v))
                    ctx.addLine(to: CGPoint(x: span.maxX, y: v))
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

        let run = extentMM.height / slope
        let diagonalSpacing: CGFloat = 120

        /// Anchor height as a fraction of the extent. The families share a `c` only at 0.5,
        /// hence the separate offsets below.
        let anchorT = extentMM.height > 0
            ? (anchorMM.y - extentMM.minY) / extentMM.height : 0.5

        /// One family of ~30-degree diagonals; `rising` picks which end carries the run.
        /// `c` is the x at the extent's bottom edge, or its top edge when falling.
        func diagonals(rising: Bool, width: CGFloat, color: CGColor) {
            ctx.setLineWidth(line(width))
            ctx.setStrokeColor(color)

            // Phased so one crossing lands on the anchor.
            let onAnchor = rising
                ? anchorMM.x - anchorT * run
                : anchorMM.x - (1 - anchorT) * run
            // Walk back to a line before the first that can touch the extent, keeping the
            // phase; a spacing of slack either side covers the overrun.
            let first = extentMM.minX - run - diagonalSpacing
            var c = onAnchor - ((onAnchor - first) / diagonalSpacing).rounded(.up) * diagonalSpacing
            let over = (extentMM.minY - span.minY) / slope

            while c <= extentMM.maxX + diagonalSpacing {
                let (bottom, top) = rising ? (c - over, c + run + over)
                                           : (c + run + over, c - over)
                ctx.move(to: CGPoint(x: bottom, y: span.minY))
                ctx.addLine(to: CGPoint(x: top, y: span.maxY))
                c += diagonalSpacing
            }
            ctx.strokePath()
        }

        // 10 mm grid, faint — gives a scale reference across both panels.
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
        // radii keep every ring meeting the rules and the grid.
        ctx.setLineWidth(line(0.9))
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.8))
        // Reach the farthest corner; the anchor can sit well off its centre.
        let reach = hypot(max(anchorMM.x - span.minX, span.maxX - anchorMM.x),
                          max(anchorMM.y - span.minY, span.maxY - anchorMM.y))
        var r: CGFloat = 50
        while r < reach {
            ctx.addArc(center: anchorMM, radius: r,
                       startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.strokePath()
            r += 50
        }
    }
}
