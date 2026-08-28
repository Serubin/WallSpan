// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit
import CryptoKit
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
    public static func renderKey(source: URL, layout: PhysicalLayout, mode: String = "union") -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let canonical = "\(source.path)|\(mtime)|\(size)|\(layout.fingerprint)|\(mode)"
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Encodes to a sibling temp file and swaps it in.
    ///
    /// Writing the final path directly leaves a truncated PNG if the process dies mid
    /// encode, and `materialize` tests the cache by existence alone — so a partial file
    /// would be served as a hit forever. With the swap, a file that exists is complete.
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

    /// Per-display file name, keyed by UUID rather than `CGDirectDisplayID`.
    ///
    /// The render key hashes the UUID-based physical fingerprint, so ID-named files miss
    /// after every reassignment and re-render a second set beside the unreachable ones.
    static func screenFile(in dir: URL, uuid: String) -> URL {
        dir.appendingPathComponent("screen_\(uuid).png")
    }

    /// How many render sets to keep. Without a cap, a cycling agent over a large folder
    /// grows the cache forever - one directory of multi-megabyte PNGs per image.
    static let cacheLimit = 50

    /// Marks a render set as most recently used, so eviction is LRU rather than
    /// first-rendered-first-out.
    static func touch(_ dir: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: dir.path
        )
    }

    /// Evicts the least recently used render sets beyond `cacheLimit`. The set just
    /// touched is always the newest, so the wallpaper in use is never the one deleted.
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
                guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                else { return nil }
                return (n.uint32Value, screen)
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
            Thread.sleep(forTimeInterval: 0.1)
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
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            return WallspanState.Snapshot(
                displayID: n.uint32Value,
                uuid: PhysicalLayoutStore.uuid(for: n.uint32Value),
                path: NSWorkspace.shared.desktopImageURL(for: screen)?.path
            )
        }
    }

    /// Puts back a previously captured snapshot, returning what it actually restored.
    ///
    /// Matches on UUID: `CGDirectDisplayID` is reassigned across reboots and reconnects, so
    /// keying on it puts wallpapers back on the wrong screens after a swap. Snapshots
    /// written before `uuid` was recorded fall back to it.
    @discardableResult
    public static func restore(
        _ snapshots: [WallspanState.Snapshot]
    ) throws -> [(display: String, path: String)] {
        var restored: [(display: String, path: String)] = []
        for screen in NSScreen.screens {
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            let id = n.uint32Value
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
