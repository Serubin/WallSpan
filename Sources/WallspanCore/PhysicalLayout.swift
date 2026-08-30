// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit

/// Where one panel's *active area* sits in the shared physical plane, in millimetres;
/// origin bottom-left, y-up. `sizeMM` is seeded from `CGDisplayScreenSize` but meant to be
/// overridden: EDID is often wrong — an LG here reports 801.6 x 329.5 mm for a 3440x1440
/// panel, non-square pixels a 34" ultrawide does not have.
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
        return sha256Hex(canonical)
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

    /// Largest configured gap, in mm. Above a fraction of one, a spanned image is
    /// discontinuous across the seam by design.
    public var maxGapMM: CGFloat {
        horizontalGaps.map { abs($0.gapMM) }.max() ?? 0
    }

    /// Gap to each panel's nearest right-hand neighbour, for `layout show`. Nearest only:
    /// every ordered pair also matches panels with a third between them, reporting a whole
    /// panel's width as a gap and inflating `maxGapMM`.
    public var horizontalGaps: [(left: String, right: String, gapMM: CGFloat)] {
        entries.compactMap { a in
            let ar = a.placement.rectMM
            let neighbour = entries.filter { b in
                guard b.placement.uuid != a.placement.uuid else { return false }
                let br = b.placement.rectMM
                let overlap = min(ar.maxY, br.maxY) - max(ar.minY, br.minY)
                return br.minX - ar.maxX >= -0.01 && overlap > 10
            }.min { $0.placement.rectMM.minX < $1.placement.rectMM.minX }

            guard let b = neighbour else { return nil }
            return (a.placement.name, b.placement.name, b.placement.rectMM.minX - ar.maxX)
        }
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

    static let file = JSONFile<LayoutConfig>(url: PhysicalLayoutStore.configURL)

    public static func load() -> LayoutConfig { file.load(default: LayoutConfig()) }
    public static func save(_ cfg: LayoutConfig) throws { try file.save(cfg) }

    /// Derives placements that reproduce the current arrangement, so seeding is a no-op.
    ///
    /// Horizontally: edge-to-edge in left-to-right order, so the gap is exactly 0.
    /// Vertically: the exact inverse of `DisplayArranger.plan`, by fixed-point iteration —
    /// `plan` matches physical heights per-panel density, so there is no closed form.
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

        refineVertical(&cfg, from: layout)
        return cfg
    }

    /// Refines placement y until `plan` would leave the arrangement untouched. `only`
    /// limits which placements may move, so a newcomer solves without disturbing others.
    static func refineVertical(
        _ cfg: inout LayoutConfig, from layout: Layout, only: Set<String>? = nil
    ) {
        for _ in 0..<24 {
            let entries = layout.displays.compactMap { d -> (DisplayInfo, Placement)? in
                guard let u = uuid(for: d.id), let p = cfg.placements[u] else { return nil }
                return (d, p)
            }
            guard let probe = try? PhysicalLayout(entries: entries) else { return }
            var worst = 0.0
            for t in DisplayArranger.plan(probe) {
                if let only, !only.contains(t.uuid) { continue }
                let err = Double(t.requestedYDown - t.currentYDown)
                guard var p = cfg.placements[t.uuid] else { continue }
                let ptMM = DisplayArranger.ptPerMM(t.display, p)
                guard ptMM > 0 else { continue }
                p.originMM.y += CGFloat(err / ptMM)
                cfg.placements[t.uuid] = p
                worst = max(worst, abs(err))
            }
            if worst < 0.25 { return }
        }
    }

    /// Places a newly attached display alongside the calibrated ones.
    ///
    /// Re-seeding would repack every panel from the origin using raw EDID sizes, discarding
    /// calibration. Instead butt the newcomer against its nearest placed neighbour and
    /// shift the panels beyond it by its width, preserving every measured gap.
    static func insert(
        _ d: DisplayInfo, uuid newUUID: String, into cfg: inout LayoutConfig, from layout: Layout
    ) {
        let size = edidSizeMM(for: d.id)
        let ordered = layout.displays.sorted { $0.frame.minX < $1.frame.minX }
        let idx = ordered.firstIndex { $0.id == d.id } ?? 0
        func placement(_ x: DisplayInfo) -> Placement? {
            uuid(for: x.id).flatMap { cfg.placements[$0] }
        }
        let left = ordered[..<idx].reversed().compactMap(placement).first
        let right = ordered[(idx + 1)...].compactMap(placement).first

        var origin = CGPoint(x: 0, y: 0)
        if let left {
            origin.x = left.rectMM.maxX
            for other in ordered[(idx + 1)...] {
                guard let u = uuid(for: other.id), var p = cfg.placements[u] else { continue }
                p.originMM.x += size.width
                cfg.placements[u] = p
            }
        } else if let right {
            origin.x = right.originMM.x - size.width
        }

        // Start y from an already-placed panel through the logical arrangement; the fixed
        // point below then corrects for the density difference between the two.
        if let ref = layout.displays.first(where: { placement($0) != nil }),
           let refP = placement(ref) {
            let refPtMM = DisplayArranger.ptPerMM(ref, refP)
            if refPtMM > 0 {
                let dy = Double(CGDisplayBounds(d.id).origin.y - CGDisplayBounds(ref.id).origin.y)
                let topMM = Double(refP.originMM.y + refP.sizeMM.height) - dy / refPtMM
                origin.y = CGFloat(topMM) - size.height
            }
        }

        cfg.placements[newUUID] = Placement(
            uuid: newUUID, name: d.name, originMM: origin, sizeMM: size
        )
        refineVertical(&cfg, from: layout, only: [newUUID])
    }

    /// Builds the layout for the displays attached now, seeding any the config has never
    /// seen (a newly connected monitor) rather than failing.
    public static func current() throws -> PhysicalLayout {
        let logical = try Layout.current()
        var cfg = load()

        var ids: [(display: DisplayInfo, uuid: String)] = []
        for d in logical.displays {
            guard let u = uuid(for: d.id) else { throw PhysicalLayoutError.noUUID(d.name) }
            ids.append((d, u))
        }

        var dirty = false
        if ids.allSatisfy({ cfg.placements[$0.uuid] == nil }) {
            // Nothing calibrated for anything attached, so seed is the baseline. Merged per
            // UUID, never assigned over `cfg`: seed omits detached displays, so replacing
            // the config would drop their calibration.
            let seeded = try seed(from: logical)
            for (d, u) in ids {
                guard let p = seeded.placements[u] else { throw PhysicalLayoutError.noUUID(d.name) }
                cfg.placements[u] = p
            }
            dirty = true
        } else {
            for (d, u) in ids where cfg.placements[u] == nil {
                insert(d, uuid: u, into: &cfg, from: logical)
                dirty = true
            }
        }

        let entries = try ids.map { (d, u) -> (DisplayInfo, Placement) in
            guard let p = cfg.placements[u] else { throw PhysicalLayoutError.noUUID(d.name) }
            return (d, p)
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
