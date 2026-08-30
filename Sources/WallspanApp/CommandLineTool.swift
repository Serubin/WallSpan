// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import Foundation

/// Puts the bundled `wallspan` on PATH, as an editor's "install shell command" does.
///
/// A symlink, not a copy: a copy would go stale, and since the app prefers PATH over its
/// own bundle it would then be running that stale copy.
enum CommandLineTool {
    static var destinationDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
    }

    static var destination: URL { destinationDirectory.appendingPathComponent("wallspan") }

    enum State {
        /// Already a symlink into this app bundle.
        case installed
        case notInstalled
        /// Something else is there — another install, or a link to a different bundle.
        case occupiedBy(URL)
    }

    static func state(bundled: URL?) -> State {
        let fm = FileManager.default
        guard let existing = try? fm.destinationOfSymbolicLink(atPath: destination.path) else {
            return fm.fileExists(atPath: destination.path)
                ? .occupiedBy(destination)
                : .notInstalled
        }
        let resolved = URL(fileURLWithPath: existing, relativeTo: destinationDirectory)
            .standardizedFileURL
        if let bundled, resolved == bundled.standardizedFileURL { return .installed }
        return .occupiedBy(resolved)
    }

    /// Returns nil on success, or a message worth showing. `replacing` must be true to
    /// overwrite anything already at the destination — the caller asks first.
    static func install(bundled: URL, replacing: Bool) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            // `fileExists` follows symlinks, so a link to a deleted target reads as absent
            // and the create below would then fail with EEXIST. Check the link itself.
            let present = (try? fm.attributesOfItem(atPath: destination.path)) != nil
            if present {
                guard replacing else { return "\(destination.path) already exists" }
                try fm.removeItem(at: destination)
            }
            try fm.createSymbolicLink(at: destination, withDestinationURL: bundled)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Whether the destination is actually on PATH, so the menu can say so rather than
    /// leaving someone to wonder why `wallspan` still is not found.
    static func isOnPath() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return false }
        let wanted = destinationDirectory.standardizedFileURL.path
        if path.split(separator: ":").contains(where: { String($0) == wanted }) { return true }
        // The app's own PATH comes from launchd and is nearly empty, so a negative there
        // means nothing. Ask the login shell, which is the PATH that matters.
        guard let resolved = BinaryResolver.fromLoginShell() else { return false }
        return resolved.deletingLastPathComponent().standardizedFileURL.path == wanted
    }
}
