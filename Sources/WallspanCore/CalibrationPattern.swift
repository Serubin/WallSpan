// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit
import CalibrationLattice

/// A wallpaper designed to make bezel misalignment obvious: `CalibrationLattice`, rasterised
/// over the whole union and pushed through the normal pipeline, so it is subject to the
/// layout being calibrated.
public enum CalibrationPattern {
    /// - Parameter unionMM: the physical union being calibrated.
    /// - Parameter anchorMM: where the whole lattice is pinned — see `PhysicalLayout.anchorMM`.
    /// - Parameter pxPerMM: rasterisation density; the pattern is resolution-independent.
    public static func make(unionMM: CGRect, anchorMM: CGPoint, pxPerMM: CGFloat) -> CGImage? {
        let w = Int((unionMM.width * pxPerMM).rounded())
        let h = Int((unionMM.height * pxPerMM).rounded())
        guard w > 0, h > 0, let ctx = SpanRenderer.context(pixelWidth: w, pixelHeight: h)
        else { return nil }

        ctx.setFillColor(CalibrationLattice.backdrop)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: pxPerMM, y: pxPerMM)
        ctx.translateBy(x: -unionMM.minX, y: -unionMM.minY)
        CalibrationLattice.draw(in: ctx, extentMM: unionMM, anchorMM: anchorMM,
                                minLineMM: 1 / pxPerMM)
        return ctx.makeImage()
    }
}
