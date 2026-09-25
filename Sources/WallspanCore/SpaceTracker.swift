// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit

/// Which Space is in front on each display, and which Spaces already hold an image.
///
/// macOS keeps a separate wallpaper per Space and `setDesktopImageURL` reaches only the
/// one in front, so `cycle` follows Space switches. That call costs ~2.4s of CPU across
/// WallpaperAgent and WallpaperImageExtension, fixed regardless of the image's format,
/// byte size or pixel count, and macOS does not skip it when the URL is already set.
/// Not making the call is the only saving available.
public enum SpaceTracker {
    /// SkyLight, resolved lazily. CoreGraphics re-exports the same symbols; SkyLight is
    /// where they live.
    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY
    )

    private typealias ConnectionID = Int32
    private typealias MainConnectionFn = @convention(c) () -> ConnectionID
    private typealias CurrentSpaceFn = @convention(c) (ConnectionID, CFString) -> UInt64

    private static let symbols: (connection: ConnectionID, currentSpace: CurrentSpaceFn)? = {
        guard let handle,
              let mainSym = dlsym(handle, "CGSMainConnectionID"),
              let spaceSym = dlsym(handle, "CGSManagedDisplayGetCurrentSpace")
        else { return nil }
        let main = unsafeBitCast(mainSym, to: MainConnectionFn.self)
        return (main(), unsafeBitCast(spaceSym, to: CurrentSpaceFn.self))
    }()

    /// Whether the front Space can be identified at all. False means every caller must
    /// fall back to applying unconditionally.
    public static var isAvailable: Bool { symbols != nil }

    /// The Space in front on one display, or nil if it cannot be determined.
    ///
    /// Per display, not global: `CGSGetActiveSpace` answers only for the display holding
    /// the menu bar, which was measured reporting one Space while the second display
    /// showed another entirely.
    ///
    /// The `UInt64` id rather than the Space's UUID, which would survive recycling: the id
    /// is what was measured already updated *inside* the
    /// `activeSpaceDidChangeNotification` handler, whereas the UUID comes from
    /// `CGSCopyManagedDisplaySpaces`, whose freshness there is unverified. `Coverage`
    /// bounds recycling with a TTL instead.
    public static func currentSpace(displayUUID: String) -> UInt64? {
        guard let symbols else { return nil }
        let space = symbols.currentSpace(symbols.connection, displayUUID as CFString)
        // 0 means CGS does not manage this display; as an id it would alias every Space on
        // an asleep or AirPlay panel onto one key, which then reads as permanently covered.
        return space == 0 ? nil : space
    }

    /// False while another user is on the console: our Space ids then describe a session
    /// we are not on, and applying would target Spaces nobody is looking at.
    public static var isOnConsole: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as NSDictionary? else { return false }
        return session[kCGSessionOnConsoleKey as String] as? Bool ?? false
    }
}

/// Which `(display, Space)` pairs are known to hold the current image.
///
/// Emptied whenever something could have reset a Space's wallpaper behind our back — a new
/// image, display reconfiguration, wake, a console switch. Those clears are what keep an
/// entry honest; the TTL only bounds growth, since a Space is re-asserted on arrival once
/// the entry is gone.
public struct Coverage {
    public struct Key: Hashable {
        public let display: String
        public let space: UInt64

        public init(display: String, space: UInt64) {
            self.display = display
            self.space = space
        }
    }

    private var covered: [Key: Date] = [:]
    /// Used when no interval is known yet; any real interval replaces it.
    public static let defaultTTL: TimeInterval = 900

    public init() {}

    /// How long an entry is trusted. Matched to the cycle interval, which is also when the
    /// next image clears the map outright, so this only bounds growth and catches an entry
    /// recorded against an interval that has since been shortened.
    public var ttl: TimeInterval = Coverage.defaultTTL

    public mutating func setTTL(interval: TimeInterval) {
        ttl = interval > 0 ? interval : Coverage.defaultTTL
    }

    public var isEmpty: Bool { covered.isEmpty }

    public mutating func clear() { covered.removeAll() }

    public mutating func record(display: String, space: UInt64, at now: Date = Date()) {
        covered[Key(display: display, space: space)] = now
    }

    public func holds(display: String, space: UInt64, at now: Date = Date()) -> Bool {
        guard let stamped = covered[Key(display: display, space: space)] else { return false }
        return now.timeIntervalSince(stamped) < ttl
    }

    /// Drops expired entries so the map cannot grow without bound across a long run.
    public mutating func prune(at now: Date = Date()) {
        covered = covered.filter { now.timeIntervalSince($0.value) < ttl }
    }
}
