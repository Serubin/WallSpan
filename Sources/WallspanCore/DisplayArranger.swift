// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit

/// Pushes the calibrated physical layout into macOS's own display arrangement, which
/// decides where the cursor crosses between screens and where windows land.
/// `CGConfigureDisplayOrigin` sets exact integer origins; System Settings only drags
/// rectangles, too coarse for panels of different heights.
///
/// **Vertical only.** macOS forces displays to be contiguous, so a bezel gap cannot be
/// expressed in the arrangement — which is why wallspan models it separately.
public enum DisplayArranger {
    public struct Target {
        public let display: DisplayInfo
        public let uuid: String
        public let currentYDown: Int
        public let requestedYDown: Int
        /// Residual misalignment at the extremes of the shared overlap, in points.
        /// Nonzero whenever panel densities differ — see `plan`.
        public let residualTopPt: Double
        public let residualBottomPt: Double
        public var delta: Int { requestedYDown - currentYDown }
    }

    public enum ArrangeError: Error, CustomStringConvertible {
        case configFailed(String, Int32)
        case notHonoured([(String, Int, Int)])

        public var description: String {
            switch self {
            case .configFailed(let stage, let code):
                return "\(stage) failed with CGError \(code)"
            case .notHonoured(let items):
                return "macOS did not honour the requested origin:\n"
                    + items.map { "    \($0.0): requested y=\($0.1), got y=\($0.2)" }
                        .joined(separator: "\n")
            }
        }
    }

    /// Points per millimetre, vertically. Logical frame height, not pixel height:
    /// `CGDisplayBounds` and the global arrangement are in points.
    static func ptPerMM(_ d: DisplayInfo, _ p: Placement) -> Double {
        Double(d.frame.height) / Double(p.sizeMM.height)
    }

    /// Computes where each non-main display should sit.
    ///
    /// Panels of differing density cannot agree at every height — macOS's global space has
    /// no notion of physical size — so one height must be the match point, with error
    /// growing away from it. The centre of the shared overlap halves the worst case.
    public static func plan(_ layout: PhysicalLayout) -> [Target] {
        guard let ref = layout.entries.first else { return [] }
        let refBounds = CGDisplayBounds(ref.display.id)
        let refPtMM = ptPerMM(ref.display, ref.placement)
        let refTopMM = Double(ref.placement.originMM.y + ref.placement.sizeMM.height)
        let refBottomMM = Double(ref.placement.originMM.y)

        return layout.entries.dropFirst().map { e in
            let (d, p) = (e.display, e.placement)
            let ptMM = ptPerMM(d, p)
            let topMM = Double(p.originMM.y + p.sizeMM.height)
            let bottomMM = Double(p.originMM.y)

            // Physical extent both panels share; midpoint is where we make them agree.
            let overlapLo = max(bottomMM, refBottomMM)
            let overlapHi = min(topMM, refTopMM)
            let cMM = overlapHi > overlapLo ? (overlapLo + overlapHi) / 2 : (topMM + bottomMM) / 2

            let globalYatC = Double(refBounds.origin.y) + (refTopMM - cMM) * refPtMM
            let yDown = globalYatC - (topMM - cMM) * ptMM

            // Drift between the two panels at the edges of the overlap; purely density.
            func drift(at mm: Double) -> Double {
                let onRef = Double(refBounds.origin.y) + (refTopMM - mm) * refPtMM
                let onThis = yDown.rounded() + (topMM - mm) * ptMM
                return onThis - onRef
            }

            return Target(
                display: d, uuid: p.uuid,
                currentYDown: Int(CGDisplayBounds(d.id).origin.y.rounded()),
                requestedYDown: Int(yDown.rounded()),
                residualTopPt: drift(at: overlapHi),
                residualBottomPt: drift(at: overlapLo)
            )
        }
    }

    public static func currentArrangement(_ layout: PhysicalLayout) -> [WallspanState.ArrangementSnapshot] {
        layout.entries.map { e in
            let b = CGDisplayBounds(e.display.id)
            return WallspanState.ArrangementSnapshot(
                uuid: e.placement.uuid, name: e.placement.name,
                x: Int(b.origin.x.rounded()), y: Int(b.origin.y.rounded())
            )
        }
    }

    /// Applies origins and confirms macOS honoured them: a display is documented to move
    /// to "the closest valid position", so macOS may snap to remove gaps or overlaps.
    public static func apply(_ origins: [(id: CGDirectDisplayID, name: String, x: Int, y: Int)]) throws {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else {
            throw ArrangeError.configFailed("CGBeginDisplayConfiguration", begin.rawValue)
        }
        for o in origins {
            let err = CGConfigureDisplayOrigin(config, o.id, Int32(o.x), Int32(o.y))
            guard err == .success else {
                CGCancelDisplayConfiguration(config)
                throw ArrangeError.configFailed("CGConfigureDisplayOrigin(\(o.name))", err.rawValue)
            }
        }
        let done = CGCompleteDisplayConfiguration(config, .permanently)
        guard done == .success else {
            throw ArrangeError.configFailed("CGCompleteDisplayConfiguration", done.rawValue)
        }

        // The reconfiguration is asynchronous; let it settle before reading back.
        Thread.sleep(forTimeInterval: 1.0)
        var wrong: [(String, Int, Int)] = []
        for o in origins {
            let got = Int(CGDisplayBounds(o.id).origin.y.rounded())
            if got != o.y { wrong.append((o.name, o.y, got)) }
        }
        if !wrong.isEmpty { throw ArrangeError.notHonoured(wrong) }
    }
}
