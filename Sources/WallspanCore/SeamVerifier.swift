// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit

/// Checks that a spanned render is continuous across a shared display edge, by asking
/// whether the pixel gradient *at the join* is ordinary compared to the gradient within
/// each display. Comparing the boundary columns for equality does not work: adjacent
/// columns can differ a lot on detail, and a badly shifted flat area still matches.
///
/// IMPORTANT: the premise assumes edge-to-edge panels. A calibrated bezel gap makes the
/// seam discontinuous by construction, so both entry points refuse to run on a gapped
/// layout; `MappingVerifier` is the gap-aware check.
public enum SeamVerifier {
    /// Largest configured gap, in mm. Above a fraction of one, continuity is void.
    public static func maxGapMM(_ layout: PhysicalLayout) -> CGFloat {
        layout.horizontalGaps.map { abs($0.gapMM) }.max() ?? 0
    }

    public struct Report: CustomStringConvertible {
        public let left: String
        public let right: String
        public let rowsSampled: Int
        public let joinGradient: Double
        public let interiorGradient: Double
        public var ratio: Double { interiorGradient > 0 ? joinGradient / interiorGradient : 0 }

        /// Two-sided on purpose: well above 1 is a discontinuity at the join, near 0 means
        /// the boundary columns are near-duplicates — an off-by-one repeating a column.
        /// A per-image sanity check, not a proof; on a near-flat image a one-pixel shift
        /// is unmeasurable.
        public var passed: Bool {
            guard interiorGradient > 1.0 else { return true }
            return ratio < 2.0 && ratio > 0.25
        }

        public var description: String {
            String(format: """
                seam %@ | %@
                  rows sampled       : %d
                  gradient at join   : %.3f
                  gradient interior  : %.3f
                  ratio              : %.3f
                  %@
                """, left, right, rowsSampled, joinGradient, interiorGradient, ratio,
                passed ? "PASS" : "FAIL - join is an outlier")
        }
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

    public struct SelfTestReport: CustomStringConvertible {
        public struct Sample {
            public let offset: Int
            public let join: Double
            public let interior: Double
            /// Deliberately NOT `join` alone: a one-pixel shift duplicates the boundary
            /// columns, driving the join gradient to 0 — which would win a minimisation.
            /// Correct geometry makes the join *typical*, not smooth.
            public var score: Double { abs(join - interior) }
        }

        public let sweep: [Sample]
        public var best: Int { sweep.min { $0.score < $1.score }?.offset ?? 99 }
        public var passed: Bool { best == 0 }

        public var description: String {
            var out = "offset sweep - correct geometry makes the join statistically TYPICAL,\n"
            out += "so the score to minimise is |join - interior|, not the join alone:\n\n"
            out += "   offset      join   interior      score\n"
            for s in sweep {
                var mark = ""
                if s.offset == 0 { mark = "  <- true alignment" }
                else if s.join < 0.001 { mark = "  <- duplicated column" }
                out += String(format: "   %+d mm  %8.3f   %8.3f   %8.3f%@\n",
                              s.offset, s.join, s.interior, s.score, mark)
            }
            out += passed
                ? "\nPASS - zero offset scores best. The metric can distinguish correct geometry\n       from a misaligned one, and this render is correct."
                : "\nFAIL - offset \(best) scored better than 0; geometry is misaligned."
            return out
        }
    }

    /// Renders a synthetic pattern at a range of deliberate misalignments and confirms the
    /// true alignment scores best, validating both the geometry and the metric. Returns
    /// nil on a gapped layout, where the continuity premise does not hold.
    public static func selfTest(layout: PhysicalLayout, range: ClosedRange<Int> = -3...3) -> SelfTestReport? {
        guard maxGapMM(layout) < 0.05 else { return nil }
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
            guard let r = verify(rendered: rendered, layout: layout).first else { return nil }
            sweep.append(SelfTestReport.Sample(offset: offset, join: r.joinGradient,
                                               interior: r.interiorGradient))
        }
        return SelfTestReport(sweep: sweep)
    }

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

    public static func verify(
        rendered: [RenderedScreen], layout: PhysicalLayout, stripWidth: Int = 10
    ) -> [Report] {
        guard maxGapMM(layout) < 0.05 else { return [] }
        var byUUID: [String: RenderedScreen] = [:]
        for r in rendered { byUUID[r.placement.uuid] = r }

        var reports: [Report] = []
        for a in layout.entries {
            for b in layout.entries where a.placement.uuid != b.placement.uuid {
                let ar = a.placement.rectMM, br = b.placement.rectMM
                guard abs(br.minX - ar.maxX) < 0.05 else { continue }
                let yLo = max(ar.minY, br.minY), yHi = min(ar.maxY, br.maxY)
                guard yHi - yLo > 10 else { continue }
                guard let ai = byUUID[a.placement.uuid], let bi = byUUID[b.placement.uuid],
                      let ap = pixels(ai.image), let bp = pixels(bi.image) else { continue }

                // mm -> pixel row from top, per panel.
                let aSy = CGFloat(a.display.pixelHeight) / a.placement.sizeMM.height
                let bSy = CGFloat(b.display.pixelHeight) / b.placement.sizeMM.height

                func lum(_ p: (data: [UInt8], width: Int, height: Int), _ x: Int, _ row: Int) -> Double? {
                    guard x >= 0, x < p.width, row >= 0, row < p.height else { return nil }
                    let i = (row * p.width + x) * 4
                    return 0.2126 * Double(p.data[i]) + 0.7152 * Double(p.data[i+1]) + 0.0722 * Double(p.data[i+2])
                }

                var joinSum = 0.0, joinN = 0, interiorSum = 0.0, interiorN = 0
                var y = yLo + 2
                while y < yHi - 2 {
                    let aRow = Int(((ar.maxY - y) * aSy).rounded(.down))
                    let bRow = Int(((br.maxY - y) * bSy).rounded(.down))
                    var strip: [Double] = []
                    var ok = true
                    for c in (ap.width - stripWidth)..<ap.width {
                        guard let v = lum(ap, c, aRow) else { ok = false; break }
                        strip.append(v)
                    }
                    if ok {
                        for c in 0..<stripWidth {
                            guard let v = lum(bp, c, bRow) else { ok = false; break }
                            strip.append(v)
                        }
                    }
                    if ok, strip.count == stripWidth * 2 {
                        for i in 0..<(strip.count - 1) {
                            let g = abs(strip[i+1] - strip[i])
                            if i == stripWidth - 1 { joinSum += g; joinN += 1 }
                            else { interiorSum += g; interiorN += 1 }
                        }
                    }
                    y += 0.5
                }
                guard joinN > 0, interiorN > 0 else { continue }
                reports.append(Report(
                    left: a.placement.name, right: b.placement.name, rowsSampled: joinN,
                    joinGradient: joinSum / Double(joinN),
                    interiorGradient: interiorSum / Double(interiorN)
                ))
            }
        }
        return reports
    }
}
