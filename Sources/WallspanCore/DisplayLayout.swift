// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit

extension NSScreen {
    /// The `CGDirectDisplayID` behind this screen. Optional, not 0: 0 looks valid, so
    /// substituting it defers an unidentifiable screen's failure downstream.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// One physical display in the global (virtual desktop) coordinate space. `frame` is y-up
/// points, as `NSScreen.frame` reports it; a rotated panel already reports rotated dims.
public struct DisplayInfo: Equatable {
    public let id: CGDirectDisplayID
    public let name: String
    public let frame: CGRect
    public let scale: CGFloat

    public var pixelWidth: Int { Int((frame.width * scale).rounded()) }
    public var pixelHeight: Int { Int((frame.height * scale).rounded()) }
}

public enum LayoutError: Error, CustomStringConvertible {
    case noScreens

    public var description: String {
        switch self {
        case .noScreens: return "no displays found"
        }
    }
}

/// The full display arrangement plus the union rect that a spanned wallpaper maps onto.
public struct Layout {
    public let displays: [DisplayInfo]
    public let union: CGRect

    public init(displays: [DisplayInfo]) throws {
        guard let first = displays.first else { throw LayoutError.noScreens }
        self.displays = displays
        self.union = displays.dropFirst().reduce(first.frame) { $0.union($1.frame) }
    }

    /// Reads the arrangement macOS already knows from System Settings > Displays.
    public static func current() throws -> Layout {
        let infos = NSScreen.screens.compactMap { screen -> DisplayInfo? in
            guard let id = screen.displayID else { return nil }
            return DisplayInfo(
                id: id,
                name: screen.localizedName,
                frame: screen.frame,
                scale: screen.backingScaleFactor
            )
        }
        return try Layout(displays: infos)
    }

    /// One decode must satisfy the most demanding display, so source resolution is sized
    /// against the highest backing scale rather than per-screen.
    public var maxScale: CGFloat { displays.map(\.scale).max() ?? 1 }

    /// Fraction of the union rect covered by a display; the rest is never shown. Sums
    /// per-display areas, which would over-count on overlap — but `NSScreen.screens`
    /// reports a mirrored set as one screen. Clamped for safety.
    public var coverage: Double {
        let covered = displays.reduce(0.0) { $0 + Double($1.frame.width * $1.frame.height) }
        let total = Double(union.width * union.height)
        guard total > 0 else { return 0 }
        return min(1.0, covered / total)
    }

    /// Stable identity for the arrangement: a change of resolution, position, rotation or
    /// scale invalidates the render cache.
    public var fingerprint: String {
        let canonical = displays
            .map { "\($0.id):\($0.frame.minX),\($0.frame.minY),\($0.frame.width),\($0.frame.height)@\($0.scale)" }
            .sorted()
            .joined(separator: "|")
        return sha256Hex(canonical)
    }
}

extension Layout: CustomStringConvertible {
    public var description: String {
        var out = "displays: \(displays.count)\n"
        for (i, d) in displays.enumerated() {
            out += String(
                format: "  [%d] %@\n      frame  = (%.0f, %.0f, %.0f, %.0f) pt\n      pixels = %dx%d @%.1fx\n      id     = %u\n",
                i, d.name, d.frame.minX, d.frame.minY, d.frame.width, d.frame.height,
                d.pixelWidth, d.pixelHeight, d.scale, d.id
            )
        }
        out += String(
            format: "union: (%.0f, %.0f, %.0f, %.0f)  aspect %.4f\ncoverage: %.1f%% (%.1f%% of every source image falls in dead space)\nfingerprint: %@",
            union.minX, union.minY, union.width, union.height,
            union.width / union.height,
            coverage * 100, (1 - coverage) * 100,
            String(fingerprint.prefix(16))
        )
        return out
    }
}
