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

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw ApplyError.pngEncodeFailed(url) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ApplyError.pngEncodeFailed(url) }
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

        let displays = layout.entries.map(\.display)
        let expected = displays.map { dir.appendingPathComponent("screen_\($0.id).png") }
        if expected.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
            return zip(displays, expected).map {
                ApplyResult(display: $0, url: $1, cached: true)
            }
        }

        var results: [ApplyResult] = []
        for screen in try render() {
            let url = dir.appendingPathComponent("screen_\(screen.display.id).png")
            try writePNG(screen.image, to: url)
            results.append(ApplyResult(display: screen.display, url: url, cached: false))
        }
        return results
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
                path: NSWorkspace.shared.desktopImageURL(for: screen)?.path
            )
        }
    }

    /// Puts back a previously captured snapshot.
    public static func restore(_ snapshots: [WallspanState.Snapshot]) throws {
        for screen in NSScreen.screens {
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let path = snapshots.first(where: { $0.displayID == n.uint32Value })?.path
            else { continue }
            do {
                try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                    .allowClipping: true,
                ])
            } catch {
                throw ApplyError.setFailed(display: screen.localizedName, underlying: error)
            }
        }
    }
}
