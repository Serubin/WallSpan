// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import CoreGraphics
import Foundation

/// Whether a scheduled wallpaper change should wait for the user to stop typing.
///
/// `setDesktopImageURL` costs ~0.85s of CPU per display in WallpaperImageExtension,
/// all of it security-scoped bookmark resolution, so the burst is felt rather than
/// seen. A rotation landing a minute late costs nothing; one landing mid-keystroke
/// is the whole complaint. Only the interval tick waits — a Space switch or a
/// display change must repaint while the user is by definition at the keyboard.
public enum IdleGate {
    /// How often to re-ask while waiting. Matches the config watcher's cadence, and
    /// a poll is a single syscall.
    public static let recheckInterval: TimeInterval = 5

    /// Seconds since the last input event of any kind.
    public static func secondsSinceInput() -> TimeInterval {
        // 0xFFFFFFFF is kCGAnyInputEventType, which has no Swift spelling.
        guard let anyEvent = CGEventType(rawValue: ~0) else { return .greatestFiniteMagnitude }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyEvent)
    }

    /// nil to apply now; otherwise how long to wait before asking again.
    ///
    /// `waitingSince` is when this deferral began — on the first ask, now. Past `cap`
    /// the answer is always now, so a user who never goes idle still gets their
    /// wallpaper rotated.
    public static func retryDelay(
        idle: TimeInterval, threshold: TimeInterval,
        waitingSince: Date, cap: TimeInterval, now: Date = Date()
    ) -> TimeInterval? {
        guard threshold > 0, idle < threshold else { return nil }
        let remaining = cap - now.timeIntervalSince(waitingSince)
        guard remaining > 0 else { return nil }
        // `remaining` is not floored: rounding it up would land the apply past the cap.
        return min(recheckInterval, max(0.5, threshold - idle), remaining)
    }
}
