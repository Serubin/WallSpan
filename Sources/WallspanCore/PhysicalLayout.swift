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

/// One calibrated arrangement, identified by exactly which displays were attached.
///
/// A placement only means anything alongside the ones it was measured with: the same panel
/// sits somewhere different when it is alone than when it is beside two others. Keying
/// calibration by display alone forces those into one coordinate plane, where they overlap.
///
/// Displays are identified by UUID rather than `CGDirectDisplayID`, which is reassigned
/// across reboots and reconnects. macOS keys its own wallpaper store the same way.
public struct DisplaySet: Codable {
    public var displays: [String]
    public var placements: [String: Placement]

    public init(displays: [String], placements: [String: Placement]) {
        self.displays = displays.sorted()
        self.placements = placements
    }
}

public struct LayoutConfig: Codable {
    public var version: Int = 2
    public var sets: [DisplaySet] = []

    public init() {}

    /// The set calibrated for exactly these displays.
    public func exactIndex(for uuids: [String]) -> Int? {
        let key = uuids.sorted()
        return sets.firstIndex { $0.displays == key }
    }

    /// The calibrated set sharing the most displays, so a new combination can be derived
    /// from measurements already taken rather than starting blank.
    func bestSubsetIndex(for uuids: [String]) -> Int? {
        let want = Set(uuids)
        return sets.indices
            .map { ($0, want.intersection(sets[$0].displays).count) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
    }
}

public enum PhysicalLayoutError: Error, CustomStringConvertible {
    case noScreens
    case noActiveSet
    case noUUID(String)
    case duplicateUUID([String])
    case displayNotFound(String)
    case ambiguousDisplay(String, [String])

    public var description: String {
        switch self {
        case .noScreens: return "no displays found"
        case .noActiveSet: return "no calibration stored for the displays attached now"
        case .duplicateUUID(let names):
            return """
            these displays report the same UUID, so their calibration cannot be told
                   apart: \(names.joined(separator: ", "))
                   macOS derives the UUID from EDID, and panels that report no serial
                   number collide. Attach only one of them, or use different models.
            """
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

    /// The reference panel: the main display, or the first in the set when macOS's main
    /// display is not one of these.
    public var anchorDisplay: (display: DisplayInfo, placement: Placement) {
        entries.first { $0.display.id == CGMainDisplayID() } ?? entries[0]
    }

    /// Centre of `anchorDisplay`, in millimetres. Calibration holds the main display still
    /// and moves the others around it, so anything pinned here stays put on the one panel
    /// the eye is using as the reference.
    public var anchorMM: CGPoint {
        let r = anchorDisplay.placement.rectMM
        return CGPoint(x: r.midX, y: r.midY)
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

    /// The panel's active area, forced to square pixels.
    ///
    /// EDID's per-axis sizes are often rounded to whole centimetres, which skews each axis
    /// by up to 5 mm but barely moves the diagonal — so keep the diagonal and impose the
    /// pixel aspect. Both axes wrong the same way is a pure scale error this cannot see;
    /// that is what `layout size` is for.
    public static func panelSizeMM(for display: DisplayInfo) -> CGSize {
        let reported = edidSizeMM(for: display.id)
        let pw = CGFloat(display.pixelWidth), ph = CGFloat(display.pixelHeight)
        guard pw > 0, ph > 0, reported.width > 0, reported.height > 0 else { return reported }

        let diagonal = (reported.width * reported.width + reported.height * reported.height)
            .squareRoot()
        let aspect = pw / ph
        let width = diagonal * aspect / (aspect * aspect + 1).squareRoot()
        guard width.isFinite, width > 1 else { return reported }
        return CGSize(width: width, height: width / aspect)
    }

    /// Whether the reported size implies non-square pixels, which no flat panel has.
    public static func reportsNonSquarePixels(_ display: DisplayInfo) -> Bool {
        let mm = edidSizeMM(for: display.id)
        guard mm.width > 0, mm.height > 0 else { return false }
        let dx = CGFloat(display.pixelWidth) / mm.width
        let dy = CGFloat(display.pixelHeight) / mm.height
        return abs(dx - dy) / max(dx, dy) > 0.002
    }

    /// Resizes one panel without moving it or inventing a gap: panels to its right shift by
    /// the width delta, and its vertical centre is held. It was re-measured, not moved.
    @discardableResult
    public static func resize(
        _ uuid: String, to size: CGSize, in placements: inout [String: Placement]
    ) -> (widthDelta: CGFloat, heightDelta: CGFloat) {
        guard var p = placements[uuid] else { return (0, 0) }
        let dw = size.width - p.sizeMM.width
        let dh = size.height - p.sizeMM.height
        p.sizeMM = size
        p.originMM.y -= dh / 2
        placements[uuid] = p

        if dw != 0 {
            for (k, var other) in placements where k != uuid {
                if other.originMM.x > p.originMM.x {
                    other.originMM.x += dw
                    placements[k] = other
                }
            }
        }
        return (dw, dh)
    }

    static let file = JSONFile<LayoutConfig>(url: PhysicalLayoutStore.configURL)

    public static func load() -> LayoutConfig { file.load(default: LayoutConfig()) }
    public static func save(_ cfg: LayoutConfig) throws { try file.save(cfg) }

    /// Derives placements that reproduce the current arrangement, so seeding is a no-op.
    ///
    /// Horizontally: edge-to-edge in left-to-right order, so the gap is exactly 0.
    /// Vertically: the exact inverse of `DisplayArranger.plan`, by fixed-point iteration —
    /// `plan` matches physical heights per-panel density, so there is no closed form.
    public static func seed(from layout: Layout) throws -> [String: Placement] {
        guard !layout.displays.isEmpty else { throw PhysicalLayoutError.noScreens }

        // Left-to-right by logical position, so physical order matches what is seen.
        let ordered = layout.displays.sorted { $0.frame.minX < $1.frame.minX }
        var placements: [String: Placement] = [:]
        var cursorX: CGFloat = 0
        for d in ordered {
            guard let uuid = uuid(for: d.id) else { throw PhysicalLayoutError.noUUID(d.name) }
            let size = panelSizeMM(for: d)
            placements[uuid] = Placement(
                uuid: uuid, name: d.name,
                originMM: CGPoint(x: cursorX, y: 0), sizeMM: size
            )
            cursorX += size.width
        }

        refineVertical(&placements, from: layout)
        return placements
    }

    /// Refines placement y until `plan` would leave the arrangement untouched. `only`
    /// limits which placements may move, so a newcomer solves without disturbing others.
    static func refineVertical(
        _ placements: inout [String: Placement], from layout: Layout, only: Set<String>? = nil
    ) {
        for _ in 0..<24 {
            let entries = layout.displays.compactMap { d -> (DisplayInfo, Placement)? in
                guard let u = uuid(for: d.id), let p = placements[u] else { return nil }
                return (d, p)
            }
            guard let probe = try? PhysicalLayout(entries: entries) else { return }
            var worst = 0.0
            for t in DisplayArranger.plan(probe) {
                if let only, !only.contains(t.uuid) { continue }
                let err = Double(t.requestedYDown - t.currentYDown)
                guard var p = placements[t.uuid] else { continue }
                let ptMM = DisplayArranger.ptPerMM(t.display, p)
                guard ptMM > 0 else { continue }
                p.originMM.y += CGFloat(err / ptMM)
                placements[t.uuid] = p
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
        _ d: DisplayInfo, uuid newUUID: String,
        into placements: inout [String: Placement], from layout: Layout
    ) {
        let size = panelSizeMM(for: d)
        let ordered = layout.displays.sorted { $0.frame.minX < $1.frame.minX }
        let idx = ordered.firstIndex { $0.id == d.id } ?? 0
        func placement(_ x: DisplayInfo) -> Placement? {
            uuid(for: x.id).flatMap { placements[$0] }
        }
        let left = ordered[..<idx].reversed().compactMap(placement).first
        let right = ordered[(idx + 1)...].compactMap(placement).first

        var origin = CGPoint(x: 0, y: 0)
        if let left {
            origin.x = left.rectMM.maxX
            for other in ordered[(idx + 1)...] {
                guard let u = uuid(for: other.id), var p = placements[u] else { continue }
                p.originMM.x += size.width
                placements[u] = p
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

        placements[newUUID] = Placement(
            uuid: newUUID, name: d.name, originMM: origin, sizeMM: size
        )
        refineVertical(&placements, from: layout, only: [newUUID])
    }

    /// Builds the layout for the displays attached now, seeding any the config has never
    /// seen (a newly connected monitor) rather than failing.
    /// The displays attached right now, sorted - the key into `LayoutConfig.sets`.
    public static func activeKey() throws -> [String] {
        try Layout.current().displays.map {
            guard let u = uuid(for: $0.id) else { throw PhysicalLayoutError.noUUID($0.name) }
            return u
        }.sorted()
    }

    /// The config plus the index of the set for the displays attached now.
    ///
    /// `current()` creates that set, so any caller that has resolved a layout will find it.
    public static func loadActive() throws -> (cfg: LayoutConfig, index: Int) {
        let cfg = load()
        guard let i = cfg.exactIndex(for: try activeKey()) else {
            throw PhysicalLayoutError.noActiveSet
        }
        return (cfg, i)
    }

    public static func current() throws -> PhysicalLayout {
        let logical = try Layout.current()
        var ids: [(display: DisplayInfo, uuid: String)] = []
        for d in logical.displays {
            guard let u = uuid(for: d.id) else { throw PhysicalLayoutError.noUUID(d.name) }
            ids.append((d, u))
        }
        let key = ids.map(\.uuid).sorted()
        // Two panels sharing a UUID would silently share one placement, so every edit to
        // either would move both. Refuse rather than mis-calibrate: CGDisplayUnitNumber
        // tells them apart within a session but is reassigned, so it cannot be persisted.
        guard Set(key).count == key.count else {
            let dupes = Dictionary(grouping: ids, by: \.uuid)
                .filter { $0.value.count > 1 }
                .flatMap { $0.value.map(\.display.name) }
            throw PhysicalLayoutError.duplicateUUID(dupes.sorted())
        }

        var cfg = load()
        var dirty = false
        var placements: [String: Placement]

        let setIndex: Int
        if let i = cfg.exactIndex(for: key) {
            placements = cfg.sets[i].placements
            setIndex = i
        } else {
            // Derive from whichever set shares the most displays, so plugging one more in
            // inherits the gaps already measured instead of starting blank. Only when
            // nothing overlaps is a from-scratch seed the right baseline.
            if let j = cfg.bestSubsetIndex(for: key) {
                placements = cfg.sets[j].placements.filter { key.contains($0.key) }
                for (d, u) in ids where placements[u] == nil {
                    insert(d, uuid: u, into: &placements, from: logical)
                }
            } else {
                placements = try seed(from: logical)
            }
            cfg.sets.append(DisplaySet(displays: key, placements: placements))
            setIndex = cfg.sets.count - 1
            dirty = true
        }

        // After both branches: an inherited set carries the parent's sizes, which are just
        // as likely to predate the correction as a stored set's own.
        if correctUntouchedSizes(&placements, for: ids) {
            cfg.sets[setIndex].placements = placements
            dirty = true
        }

        let entries = try ids.map { (d, u) -> (DisplayInfo, Placement) in
            guard let p = placements[u] else { throw PhysicalLayoutError.noUUID(d.name) }
            return (d, p)
        }
        if dirty { try? save(cfg) }
        return try PhysicalLayout(entries: entries)
    }

    /// Re-seeds sizes still equal to what the display reports, which proves they were never
    /// set by hand. Anything hand-measured differs, and is left alone.
    static func correctUntouchedSizes(
        _ placements: inout [String: Placement], for ids: [(display: DisplayInfo, uuid: String)]
    ) -> Bool {
        var changed = false
        for (d, u) in ids {
            guard let stored = placements[u], reportsNonSquarePixels(d) else { continue }
            let reported = edidSizeMM(for: d.id)
            // Not exact equality: the stored value round-trips through JSON.
            guard abs(stored.sizeMM.width - reported.width) < 0.05,
                  abs(stored.sizeMM.height - reported.height) < 0.05
            else { continue }
            resize(u, to: panelSizeMM(for: d), in: &placements)
            changed = true
        }
        return changed
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
                    ? "  <- non-square; set the real size with `layout size`" : "",
                p.uuid
            )
            // A correction the reader cannot see is one they cannot overrule.
            let reported = PhysicalLayoutStore.edidSizeMM(for: d.id)
            if abs(reported.width - p.sizeMM.width) > 0.05
                || abs(reported.height - p.sizeMM.height) > 0.05 {
                out += String(
                    format: "      note     = the display reports %.1f x %.1f mm (%.2f x %.2f"
                          + " px/mm); corrected to square pixels\n\n",
                    reported.width, reported.height,
                    CGFloat(d.pixelWidth) / reported.width,
                    CGFloat(d.pixelHeight) / reported.height
                )
            }
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
