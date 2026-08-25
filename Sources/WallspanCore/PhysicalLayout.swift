// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit
import CryptoKit

/// Where one panel's *active area* sits in the shared physical plane, in millimetres.
/// Origin is bottom-left, y-up, as everywhere else here.
///
/// `sizeMM` is seeded from `CGDisplayScreenSize` but meant to be overridden: EDID
/// dimensions are frequently wrong. An LG here reports 801.6 x 329.5 mm for a 3440x1440
/// panel — non-square pixels (4.291 vs 4.370 px/mm) that a 34" ultrawide does not have.
public struct Placement: Codable, Equatable {
    public var uuid: String
    public var name: String
    public var originMM: CGPoint
    public var sizeMM: CGSize

    public var rectMM: CGRect { CGRect(origin: originMM, size: sizeMM) }
}

/// The persisted calibration, keyed by display UUID rather than `CGDirectDisplayID`:
/// the integer IDs are reassigned across reboots and reconnects. macOS's own wallpaper
/// store keys its `Displays` dictionary by the same UUIDs.
public struct LayoutConfig: Codable {
    public var version: Int = 1
    public var placements: [String: Placement] = [:]

    public init() {}
}

public enum PhysicalLayoutError: Error, CustomStringConvertible {
    case noScreens
    case noUUID(String)
    case displayNotFound(String)
    case ambiguousDisplay(String, [String])

    public var description: String {
        switch self {
        case .noScreens: return "no displays found"
        case .noUUID(let n): return "could not resolve a stable UUID for display \(n)"
        case .displayNotFound(let q): return "no display matching '\(q)'"
        case .ambiguousDisplay(let q, let names):
            return "'\(q)' matches more than one display: \(names.joined(separator: ", "))"
        }
    }
}

/// The display arrangement expressed physically, which is what a spanned wallpaper is
/// actually mapped onto.
public struct PhysicalLayout {
    public let entries: [(display: DisplayInfo, placement: Placement)]
    public let unionMM: CGRect

    public init(entries: [(display: DisplayInfo, placement: Placement)]) throws {
        guard let first = entries.first else { throw PhysicalLayoutError.noScreens }
        self.entries = entries
        self.unionMM = entries.dropFirst().reduce(first.placement.rectMM) {
            $0.union($1.placement.rectMM)
        }
    }

    /// Highest pixel density across all displays, in px/mm — the density the source must
    /// be decoded at to satisfy the most demanding panel.
    public var maxPxPerMM: CGFloat {
        entries.map { e in
            max(CGFloat(e.display.pixelWidth) / e.placement.sizeMM.width,
                CGFloat(e.display.pixelHeight) / e.placement.sizeMM.height)
        }.max() ?? 1
    }

    /// Covers placements, not just logical frames, so nudging a gap invalidates the
    /// render cache instead of making calibration appear inert.
    public var fingerprint: String {
        let canonical = entries
            .map { e in
                let p = e.placement
                return "\(p.uuid):\(p.originMM.x),\(p.originMM.y),\(p.sizeMM.width),\(p.sizeMM.height)"
                    + "@\(e.display.pixelWidth)x\(e.display.pixelHeight)"
            }
            .sorted()
            .joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Fraction of the physical union covered by a panel. Lower than logical coverage once
    /// gaps exist, because bezels are modelled as real dead space.
    public var coverage: Double {
        let covered = entries.reduce(0.0) {
            $0 + Double($1.placement.sizeMM.width * $1.placement.sizeMM.height)
        }
        let total = Double(unionMM.width * unionMM.height)
        guard total > 0 else { return 0 }
        return min(1.0, covered / total)
    }

    /// Horizontal gaps between panels that sit side by side, for `layout show`.
    public var horizontalGaps: [(left: String, right: String, gapMM: CGFloat)] {
        var out: [(String, String, CGFloat)] = []
        for a in entries {
            for b in entries where a.placement.uuid != b.placement.uuid {
                // b is to the right of a, with vertical overlap worth speaking of.
                let gap = b.placement.rectMM.minX - a.placement.rectMM.maxX
                let overlap = min(a.placement.rectMM.maxY, b.placement.rectMM.maxY)
                    - max(a.placement.rectMM.minY, b.placement.rectMM.minY)
                if gap >= -0.01, overlap > 10 {
                    out.append((a.placement.name, b.placement.name, gap))
                }
            }
        }
        return out
    }
}

public enum PhysicalLayoutStore {
    public static var configURL: URL {
        StateStore.supportDirectory.appendingPathComponent("layout.json")
    }

    /// Stable identifier for a display, matching how macOS keys its own wallpaper store.
    public static func uuid(for id: CGDirectDisplayID) -> String? {
        guard let ref = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
        return CFUUIDCreateString(nil, ref.takeRetainedValue()) as String?
    }

    /// Active area in millimetres, per EDID. Already rotation-aware: a 270°-rotated panel
    /// reports its rotated extent, matching its rotated pixel size.
    public static func edidSizeMM(for id: CGDirectDisplayID) -> CGSize {
        let mm = CGDisplayScreenSize(id)
        guard mm.width > 1, mm.height > 1 else { return CGSize(width: 500, height: 300) }
        return mm
    }

    public static func load() -> LayoutConfig {
        guard let data = try? Data(contentsOf: configURL),
              let cfg = try? JSONDecoder().decode(LayoutConfig.self, from: data)
        else { return LayoutConfig() }
        return cfg
    }

    public static func save(_ cfg: LayoutConfig) throws {
        try StateStore.ensureDirectories()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(cfg).write(to: configURL, options: .atomic)
    }

    /// Derives placements that reproduce the current arrangement, so seeding is a no-op
    /// and calibration starts from a known baseline.
    ///
    /// Horizontally: edge-to-edge in the arrangement's left-to-right order, so the gap is
    /// exactly 0 however logical widths relate to physical ones.
    ///
    /// Vertically: the exact inverse of `DisplayArranger.plan`, by fixed-point iteration —
    /// `plan` matches physical heights using each panel's own density, so there is no
    /// closed form. Convergence is geometric; a handful of rounds reaches float precision.
    public static func seed(from layout: Layout) throws -> LayoutConfig {
        guard !layout.displays.isEmpty else { throw PhysicalLayoutError.noScreens }

        // Left-to-right by logical position, so physical order matches what is seen.
        let ordered = layout.displays.sorted { $0.frame.minX < $1.frame.minX }
        var cfg = LayoutConfig()
        var cursorX: CGFloat = 0
        for d in ordered {
            guard let uuid = uuid(for: d.id) else { throw PhysicalLayoutError.noUUID(d.name) }
            let size = edidSizeMM(for: d.id)
            cfg.placements[uuid] = Placement(
                uuid: uuid, name: d.name,
                originMM: CGPoint(x: cursorX, y: 0), sizeMM: size
            )
            cursorX += size.width
        }

        // Refine y until plan() would leave the arrangement untouched.
        for _ in 0..<24 {
            let entries = layout.displays.compactMap { d -> (DisplayInfo, Placement)? in
                guard let u = uuid(for: d.id), let p = cfg.placements[u] else { return nil }
                return (d, p)
            }
            guard let probe = try? PhysicalLayout(entries: entries) else { break }
            let targets = DisplayArranger.plan(probe)
            var worst = 0.0
            for t in targets {
                let err = Double(t.requestedYDown - t.currentYDown)
                guard var p = cfg.placements[t.uuid] else { continue }
                let ptMM = DisplayArranger.ptPerMM(t.display, p)
                guard ptMM > 0 else { continue }
                p.originMM.y += CGFloat(err / ptMM)
                cfg.placements[t.uuid] = p
                worst = max(worst, abs(err))
            }
            if worst < 0.25 { break }
        }
        return cfg
    }

    /// Builds the layout for the displays attached now, seeding any the config has never
    /// seen (a newly connected monitor) rather than failing.
    public static func current() throws -> PhysicalLayout {
        let logical = try Layout.current()
        var cfg = load()
        var dirty = false

        var entries: [(DisplayInfo, Placement)] = []
        for d in logical.displays {
            guard let uuid = uuid(for: d.id) else { throw PhysicalLayoutError.noUUID(d.name) }
            if let existing = cfg.placements[uuid] {
                entries.append((d, existing))
            } else {
                let seeded = try seed(from: logical)
                guard let p = seeded.placements[uuid] else { throw PhysicalLayoutError.noUUID(d.name) }
                cfg.placements[uuid] = p
                dirty = true
                entries.append((d, p))
            }
        }
        if dirty { try? save(cfg) }
        return try PhysicalLayout(entries: entries)
    }

    /// Resolves "0", "dell", "LG ULTRAGEAR" to one attached display.
    public static func resolve(_ query: String, in layout: PhysicalLayout) throws -> String {
        if let idx = Int(query), idx >= 0, idx < layout.entries.count {
            return layout.entries[idx].placement.uuid
        }
        let q = query.lowercased()
        let hits = layout.entries.filter { $0.placement.name.lowercased().contains(q) }
        if hits.isEmpty { throw PhysicalLayoutError.displayNotFound(query) }
        if hits.count > 1 {
            throw PhysicalLayoutError.ambiguousDisplay(query, hits.map(\.placement.name))
        }
        return hits[0].placement.uuid
    }
}

extension PhysicalLayout: CustomStringConvertible {
    public var description: String {
        var out = "physical layout (millimetres, y-up, origin = bottom-left of active area)\n\n"
        for (i, e) in entries.enumerated() {
            let p = e.placement, d = e.display
            let pxPerMMx = CGFloat(d.pixelWidth) / p.sizeMM.width
            let pxPerMMy = CGFloat(d.pixelHeight) / p.sizeMM.height
            let ppi = pxPerMMx * 25.4
            out += String(
                format: """
                  [%d] %@
                      origin   = (%.1f, %.1f) mm
                      size     = %.1f x %.1f mm   (%d x %d px)
                      density  = %.3f x %.3f px/mm  (%.1f PPI)%@
                      uuid     = %@

                """,
                i, p.name, p.originMM.x, p.originMM.y,
                p.sizeMM.width, p.sizeMM.height, d.pixelWidth, d.pixelHeight,
                pxPerMMx, pxPerMMy, ppi,
                abs(pxPerMMx - pxPerMMy) > 0.02
                    ? "  <- non-square; EDID is suspect, consider `layout size`" : "",
                p.uuid
            )
        }
        let gaps = horizontalGaps
        if gaps.isEmpty {
            out += "no side-by-side pairs detected\n"
        } else {
            for g in gaps {
                out += String(format: "  gap: %@ | %@  =  %.1f mm%@\n",
                              g.left, g.right, g.gapMM,
                              abs(g.gapMM) < 0.05 ? "   (edge-to-edge; not yet calibrated)" : "")
            }
        }
        out += String(
            format: "\nunion: (%.1f, %.1f) %.1f x %.1f mm   aspect %.4f\ncoverage: %.1f%% (%.1f%% of the image falls behind bezels or off-panel)\n",
            unionMM.minX, unionMM.minY, unionMM.width, unionMM.height,
            unionMM.width / unionMM.height,
            coverage * 100, (1 - coverage) * 100
        )
        out += "\nnote: mapping is physical, so an image is scaled to real-world size rather\n"
        out += "      than pixel-for-pixel. This is what corrects differing panel density.\n"
        return out
    }
}
