// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import Foundation
import ServiceManagement

/// Whether the *app* reopens at login — not whether wallpapers keep cycling, which is the
/// LaunchAgent and survives quitting. Conflating them is why "I quit Wallspan and my
/// wallpaper still changed" reads as a bug, so the menu keeps two switches.
enum LoginItem {
    enum State {
        case on
        case off
        /// Registered, but the user has to approve it in System Settings > General >
        /// Login Items. Distinct from `off` because the fix is a trip to Settings, not
        /// another click here.
        case needsApproval
        case unavailable(String)
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .notRegistered: return .off
        case .requiresApproval: return .needsApproval
        case .notFound: return .unavailable("the app is not where macOS expects it")
        @unknown default: return .unavailable("unknown login item state")
        }
    }

    /// Returns nil on success, or a message worth showing.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            // Registering from a build directory or a quarantined copy fails; the message
            // is the only clue, so pass it through rather than saying "could not".
            return error.localizedDescription
        }
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
