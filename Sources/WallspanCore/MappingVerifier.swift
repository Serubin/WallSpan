// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit

/// Verifies the render by inverting the mapping rather than inferring correctness from
/// local smoothness.
///
/// For a sample of output pixels it computes which source pixel the physical layout says
/// it came from, and checks the rendered value is consistent with the source there. Valid
/// in every configuration, including a calibrated layout with real bezel gaps, where the
/// seam is legitimately discontinuous and a continuity premise would not hold.
public enum MappingVerifier {
    /// Flattens a CGImage into tightly-packed RGBA8 for cheap random access.
    static func pixels(_ image: CGImage) -> (data: [UInt8], width: Int, height: Int)? {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: SpanRenderer.colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (buf, w, h) : nil
    }

    /// A high-contrast pattern with detail everywhere. Real photographs are a poor
    /// instrument: a smooth sky's interior gradient is near 0.4, so a one-pixel shift
    /// changes nothing measurable.
    public static func testPattern(size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0, let ctx = SpanRenderer.context(pixelWidth: w, pixelHeight: h)
        else { return nil }
        let c = CGPoint(x: w / 2, y: h / 2)
        ctx.setLineWidth(3)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        var r = 40
        while r < max(w, h) {
            ctx.addArc(center: c, radius: CGFloat(r), startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.strokePath()
            r += 40
        }
        ctx.setStrokeColor(CGColor(srgbRed: 0.1, green: 1, blue: 0.8, alpha: 1))
        for k in stride(from: -h, through: w, by: 120) {
            ctx.move(to: CGPoint(x: k, y: 0))
            ctx.addLine(to: CGPoint(x: k + h, y: h))
            ctx.strokePath()
        }
        return ctx.makeImage()
    }

    public struct Report: CustomStringConvertible {
        public let display: String
        public let sampled: Int
        public let mismatches: Int
        public let worstDelta: Double
        public var passed: Bool { Double(mismatches) / Double(max(sampled, 1)) < 0.02 }

        public var description: String {
            String(format: "%@  %@  sampled %d, mismatched %d (%.2f%%), worst delta %.0f",
                   passed ? "PASS" : "FAIL",
                   display.padding(toLength: 22, withPad: " ", startingAt: 0),
                   sampled, mismatches,
                   100 * Double(mismatches) / Double(max(sampled, 1)), worstDelta)
        }
    }

    public struct SelfTestReport: CustomStringConvertible {
        public struct Sample {
            public let offsetPx: Int
            public let mismatchRate: Double
            public let worstDelta: Double
        }
        public let sweep: [Sample]
        public var best: Int { sweep.min { $0.mismatchRate < $1.mismatchRate }?.offsetPx ?? 99 }
        public var zeroRate: Double { sweep.first { $0.offsetPx == 0 }?.mismatchRate ?? 1 }
        public var runnerUpRate: Double {
            sweep.filter { $0.offsetPx != 0 }.map(\.mismatchRate).min() ?? 0
        }

        /// Zero must be the minimum *by a clear margin*, not below an absolute rate: a
        /// residual at true alignment is expected, since the expected value is bilinear
        /// while CoreGraphics resamples with a higher-order filter and the pattern is all
        /// sharp edges. A geometry error changes the *ratio* to the neighbours.
        public var margin: Double { zeroRate > 0 ? runnerUpRate / zeroRate : .infinity }
        public var passed: Bool { best == 0 && margin >= 2.5 }

        public var description: String {
            var out = "offset sweep - each output pixel is checked against the source pixel\n"
            out += "the layout says it should come from. Zero offset must be exact:\n\n"
            out += "   offset   mismatched   worst delta\n"
            for s in sweep {
                out += String(format: "   %+d px    %7.2f%%     %8.0f%@\n",
                              s.offsetPx, s.mismatchRate * 100, s.worstDelta,
                              s.offsetPx == 0 ? "  <- true alignment" : "")
            }
            if passed {
                out += String(format: """

                    PASS - true alignment is the clear minimum: %.2f%% vs %.2f%% at the next
                           best offset, a %.1fx margin. Geometry is exact.
                    """, zeroRate * 100, runnerUpRate * 100, margin)
            } else if best != 0 {
                out += "\nFAIL - offset \(best) mapped better than 0; geometry is misaligned."
            } else {
                out += String(format: """

                    FAIL - zero offset is the minimum but only by %.1fx (need 2.5x). The sweep
                           cannot clearly distinguish true alignment from a one-pixel error.
                    """, margin)
            }
            return out
        }
    }

    /// Renders a high-contrast pattern at a range of deliberate pixel offsets and confirms
    /// true alignment is the only one that maps exactly.
    public static func selfTest(layout: PhysicalLayout, range: ClosedRange<Int> = -3...3) -> SelfTestReport? {
        // `debugOffset` displaces only displays after the first, so on a single display
        // every offset renders identically and `best` would be arbitrary.
        guard layout.entries.count >= 2 else { return nil }
        let density = layout.maxPxPerMM
        let size = CGSize(width: layout.unionMM.width * density,
                          height: layout.unionMM.height * density)
        guard let pattern = testPattern(size: size) else { return nil }

        var sweep: [SelfTestReport.Sample] = []
        for offset in range {
            let rendered = SpanRenderer.render(
                source: pattern, layout: layout,
                debugOffset: CGPoint(x: CGFloat(offset) / density, y: 0)
            )
            // Verified against the UNSHIFTED layout, so the offset is not cancelled out.
            let reports = verify(source: pattern, rendered: rendered, layout: layout)
            guard !reports.isEmpty else { return nil }
            let sampled = reports.reduce(0) { $0 + $1.sampled }
            let bad = reports.reduce(0) { $0 + $1.mismatches }
            sweep.append(SelfTestReport.Sample(
                offsetPx: offset,
                mismatchRate: Double(bad) / Double(max(sampled, 1)),
                worstDelta: reports.map(\.worstDelta).max() ?? 0
            ))
        }
        return SelfTestReport(sweep: sweep)
    }

    /// Tolerance is generous on purpose: the renderer interpolates, so an output pixel is
    /// a blend of a source *neighbourhood*, never a copy of one pixel. A geometry error
    /// still fails hard, because a mis-mapped pixel lands in an unrelated part of the image.
    public static func verify(
        source: CGImage, rendered: [RenderedScreen], layout: PhysicalLayout,
        samplesPerDisplay: Int = 4000, tolerance: Double = 26
    ) -> [Report] {
        guard let src = pixels(source) else { return [] }
        let srcSize = CGSize(width: source.width, height: source.height)
        let placedMM = SpanRenderer.placement(source: srcSize, union: layout.unionMM)

        return rendered.compactMap { screen -> Report? in
            guard let out = pixels(screen.image) else { return nil }
            let draw = SpanRenderer.drawRect(
                placedMM: placedMM, display: screen.display, placement: screen.placement
            )
            guard draw.width > 0, draw.height > 0 else { return nil }

            // How many source pixels feed one output pixel. The expected value is computed
            // exactly: bilinear near 1:1, box-averaged when genuinely downsampling.
            let ratio = Double(srcSize.width / draw.width)
            let boxRadius = ratio > 1.5 ? Int(ratio.rounded(.up)) : 0

            var mismatches = 0, sampled = 0
            var worst = 0.0
            // Deterministic stride rather than random sampling, so runs are reproducible.
            let stride = max(1, Int((Double(out.width * out.height) / Double(samplesPerDisplay)).squareRoot()))
            var row = stride / 2
            while row < out.height {
                var col = stride / 2
                while col < out.width {
                    // Pixel centre in the context's y-up space.
                    let cx = Double(col) + 0.5
                    let cy = Double(out.height - row) - 0.5

                    let u = (cx - Double(draw.minX)) / Double(draw.width)
                    let v = (cy - Double(draw.minY)) / Double(draw.height)
                    // Outside the drawn rect the output is the black fill, not a mapping.
                    guard u >= 0, u < 1, v >= 0, v < 1 else { col += stride; continue }

                    // Exact sub-pixel source coordinate, pixel-centre convention.
                    let fx = u * Double(src.width) - 0.5
                    let fy = (1 - v) * Double(src.height) - 0.5   // source rows run top-down

                    func texel(_ x: Int, _ y: Int) -> (Double, Double, Double) {
                        let cx = min(max(x, 0), src.width - 1)
                        let cy = min(max(y, 0), src.height - 1)
                        let i = (cy * src.width + cx) * 4
                        return (Double(src.data[i]), Double(src.data[i+1]), Double(src.data[i+2]))
                    }

                    var expected: (Double, Double, Double)
                    if boxRadius > 0 {
                        var acc = (0.0, 0.0, 0.0); var n = 0.0
                        for dy in -boxRadius...boxRadius {
                            for dx in -boxRadius...boxRadius {
                                let t = texel(Int(fx.rounded()) + dx, Int(fy.rounded()) + dy)
                                acc = (acc.0 + t.0, acc.1 + t.1, acc.2 + t.2); n += 1
                            }
                        }
                        expected = (acc.0 / n, acc.1 / n, acc.2 / n)
                    } else {
                        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
                        let tx = fx - Double(x0), ty = fy - Double(y0)
                        let p00 = texel(x0, y0), p10 = texel(x0 + 1, y0)
                        let p01 = texel(x0, y0 + 1), p11 = texel(x0 + 1, y0 + 1)
                        func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
                        expected = (
                            lerp(lerp(p00.0, p10.0, tx), lerp(p01.0, p11.0, tx), ty),
                            lerp(lerp(p00.1, p10.1, tx), lerp(p01.1, p11.1, tx), ty),
                            lerp(lerp(p00.2, p10.2, tx), lerp(p01.2, p11.2, tx), ty)
                        )
                    }

                    let j = (row * out.width + col) * 4
                    let rr = Double(out.data[j]), rg = Double(out.data[j+1]), rb = Double(out.data[j+2])
                    let d = max(abs(rr - expected.0), max(abs(rg - expected.1), abs(rb - expected.2)))
                    sampled += 1
                    if d > tolerance { mismatches += 1 }
                    worst = max(worst, d)
                    col += stride
                }
                row += stride
            }
            return Report(display: screen.display.name, sampled: sampled,
                          mismatches: mismatches, worstDelta: worst)
        }
    }
}
