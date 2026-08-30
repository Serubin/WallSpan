// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit
import ImageIO
import UniformTypeIdentifiers

public enum ApplyError: Error, CustomStringConvertible {
    case pngEncodeFailed(URL)
    case setFailed(display: String, underlying: Error)
    case readBackMismatch(display: String, expected: String, actual: String?)

    public var description: String {
        switch self {
        case .pngEncodeFailed(let u):
            return "failed to encode PNG at \(u.path)"
        case .setFailed(let d, let e):
            return "setDesktopImageURL failed for \(d): \(e.localizedDescription)"
        case .readBackMismatch(let d, let expected, let actual):
            return """
            read-back mismatch for \(d)
                  expected: \(expected)
                  actual:   \(actual ?? "nil")
            """
        }
    }
}

public struct ApplyResult {
    public let display: DisplayInfo
    public let url: URL
    public let cached: Bool
}

public enum WallpaperApplier {
    /// Identity of a render: same source bytes + same physical arrangement => same
    /// directory. Hashes the PHYSICAL fingerprint, so a `layout nudge` invalidates it;
    /// the logical one would serve stale renders and make calibration look inert.
    ///
    /// `renderer` salts the hash with the renderer's own behaviour, which the source bytes
    /// and the layout do not describe. Without it a wide-gamut wallpaper applied before
    /// the colour-space change keeps its sRGB-clipped PNGs — `materialize` treats file
    /// existence as a hit and never re-renders — so the fix would silently miss exactly
    /// the images already in use. Bump it whenever a render's output changes for
    /// unchanged inputs.
    static let renderer = "v2-source-colour-space"

    public static func renderKey(source: URL, layout: PhysicalLayout) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        return sha256Hex("\(renderer)|\(source.path)|\(mtime)|\(size)|\(layout.fingerprint)")
    }

    /// Encodes to a sibling temp file and swaps it in, so a file that exists is complete.
    /// `materialize` tests the cache by existence alone, so a PNG truncated by a crash
    /// would otherwise be served as a hit forever.
    public static func writePNG(_ image: CGImage, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard let dest = CGImageDestinationCreateWithURL(
            tmp as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw ApplyError.pngEncodeFailed(url) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ApplyError.pngEncodeFailed(url) }

        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    /// Returns per-display PNG locations, reusing the cache when possible. `render` is a
    /// closure so a cache hit skips decode and render entirely — the point of the cache,
    /// since decoding one of these sources can cost half a gigabyte of RSS.
    public static func materialize(
        source: URL, layout: PhysicalLayout, render: () throws -> [RenderedScreen]
    ) throws -> [ApplyResult] {
        try StateStore.ensureDirectories()
        let key = renderKey(source: source, layout: layout)
        let dir = StateStore.renderDirectory.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fm = FileManager.default
        let expected = layout.entries.map { screenFile(in: dir, uuid: $0.placement.uuid) }
        if expected.allSatisfy({ fm.fileExists(atPath: $0.path) }) {
            touch(dir)
            return zip(layout.entries.map(\.display), expected).map {
                ApplyResult(display: $0, url: $1, cached: true)
            }
        }

        var results: [ApplyResult] = []
        for screen in try render() {
            let url = screenFile(in: dir, uuid: screen.placement.uuid)
            try writePNG(screen.image, to: url)
            results.append(ApplyResult(display: screen.display, url: url, cached: false))
        }

        // Drop anything this set still holds that the current layout does not name -
        // ID-named files from before the UUID switch, or a display since detached.
        let keep = Set(results.map(\.url.lastPathComponent))
        for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !keep.contains(f) {
            try? fm.removeItem(at: dir.appendingPathComponent(f))
        }

        touch(dir)
        prune()
        return results
    }

    /// Per-display file name, keyed by UUID: the render key hashes the UUID-based physical
    /// fingerprint, so ID-named files miss after every reassignment.
    static func screenFile(in dir: URL, uuid: String) -> URL {
        dir.appendingPathComponent("screen_\(uuid).png")
    }

    /// How many render sets to keep; uncapped, a cycling agent grows the cache forever.
    static let cacheLimit = 50

    /// Marks a render set most recently used, so eviction is LRU.
    static func touch(_ dir: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: dir.path
        )
    }

    /// Evicts the least recently used sets beyond `cacheLimit`. The set just touched is
    /// newest, so the wallpaper in use is never evicted.
    static func prune(limit: Int = cacheLimit) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: StateStore.renderDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), dirs.count > limit else { return }

        let newestFirst = dirs.map { url -> (URL, Date) in
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (url, mtime)
        }.sorted { $0.1 > $1.1 }

        for (url, _) in newestFirst.dropFirst(limit) { try? fm.removeItem(at: url) }
    }

    /// Applies one image per display, then verifies macOS actually took it:
    /// `setDesktopImageURL` can silently no-op without a GUI audit session.
    public static func apply(_ results: [ApplyResult]) throws {
        let screensByID = Dictionary(
            uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
                screen.displayID.map { ($0, screen) }
            }
        )

        for r in results {
            guard let screen = screensByID[r.display.id] else { continue }
            do {
                try NSWorkspace.shared.setDesktopImageURL(r.url, for: screen, options: [
                    // A no-op on exact-size crops; guarantees macOS never re-fits.
                    .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue,
                    .allowClipping: true,
                    // .fillColor omitted: ignored since Sonoma, and never visible here.
                ])
            } catch {
                throw ApplyError.setFailed(display: r.display.name, underlying: error)
            }
        }

        // macOS commits the wallpaper store asynchronously and the delay varies with image
        // size and load, so poll until the read-back converges rather than sleeping once.
        let deadline = Date().addingTimeInterval(5)
        var pending = results
        var lastSeen: [CGDirectDisplayID: String?] = [:]
        while !pending.isEmpty, Date() < deadline {
            // Drain the run loop rather than sleeping it. `cycle` calls this from a Timer
            // on the main run loop, so a plain sleep froze the config watcher and the
            // display-change debounce for as long as the read-back took — up to the full
            // five seconds.
            //
            // Then sleep out the rest of the slice. `run(mode:before:)` returns as soon as
            // one input source is handled, not at the limit date, so on its own it polls
            // as fast as the main queue is busy — measured at ~660 reads in two seconds
            // under `cycle`'s own timers, against the 20 intended. Each read is an IPC
            // round-trip to the wallpaper store.
            let slice = Date().addingTimeInterval(0.1)
            RunLoop.current.run(mode: .default, before: slice)
            let remaining = slice.timeIntervalSinceNow
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
            pending.removeAll { r in
                guard let screen = screensByID[r.display.id] else { return true }
                let actual = NSWorkspace.shared.desktopImageURL(for: screen)?.path
                lastSeen[r.display.id] = actual
                return actual == r.url.path
            }
        }
        if let stuck = pending.first {
            throw ApplyError.readBackMismatch(
                display: stuck.display.name, expected: stuck.url.path,
                actual: lastSeen[stuck.display.id] ?? nil
            )
        }
    }

    public static func currentWallpapers() -> [WallspanState.Snapshot] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return WallspanState.Snapshot(
                displayID: id,
                uuid: PhysicalLayoutStore.uuid(for: id),
                path: NSWorkspace.shared.desktopImageURL(for: screen)?.path
            )
        }
    }

    /// Puts back a previously captured snapshot, returning what it actually restored.
    /// Matches on UUID - `CGDirectDisplayID` is reassigned across reboots, so keying on it
    /// restores onto the wrong screens. Pre-`uuid` snapshots fall back to the ID.
    @discardableResult
    public static func restore(
        _ snapshots: [WallspanState.Snapshot]
    ) throws -> [(display: String, path: String)] {
        var restored: [(display: String, path: String)] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let uuid = PhysicalLayoutStore.uuid(for: id)
            let match = snapshots.first { $0.uuid != nil && $0.uuid == uuid }
                ?? snapshots.first { $0.uuid == nil && $0.displayID == id }
            guard let path = match?.path else { continue }
            do {
                try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                    .allowClipping: true,
                ])
                restored.append((screen.localizedName, path))
            } catch {
                throw ApplyError.setFailed(display: screen.localizedName, underlying: error)
            }
        }
        return restored
    }
}
