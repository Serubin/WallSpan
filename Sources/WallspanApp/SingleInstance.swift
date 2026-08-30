// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit

/// Stops a second Wallspan: two would give two status items and two things pausing and
/// resuming cycling. `LSMultipleInstancesProhibited` covers Finder launches; this covers
/// running the binary directly, which is how it was first hit.
enum SingleInstance {
    /// True if this process should keep running. When another instance is already up, it is
    /// brought to the front first, so a second launch reads as "show me the one I have".
    static func claim() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return true }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let first = others.first else { return true }

        first.activate()
        return false
    }
}
