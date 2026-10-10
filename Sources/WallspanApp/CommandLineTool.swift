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

    static func state(bundled: URL?, at link: URL = CommandLineTool.destination) -> State {
        let fm = FileManager.default
        guard let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) else {
            return fm.fileExists(atPath: link.path)
                ? .occupiedBy(link)
                : .notInstalled
        }
        let resolved = URL(fileURLWithPath: existing, relativeTo: link.deletingLastPathComponent())
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
        // The app's own PATH comes from launchd and is nearly empty, so a negative there
        // means nothing. Ask the login shell, which is the PATH that matters.
        inLaunchPath || isOnPath(shellHit: BinaryResolver.fromLoginShell())
    }

    /// For a caller that already asked the login shell, so it is not asked twice.
    static func isOnPath(shellHit: URL?) -> Bool {
        if inLaunchPath { return true }
        guard let shellHit else { return false }
        return shellHit.deletingLastPathComponent().standardizedFileURL.path
            == destinationDirectory.standardizedFileURL.path
    }

    private static var inLaunchPath: Bool {
        let wanted = destinationDirectory.standardizedFileURL.path
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").contains { String($0) == wanted }
    }

    /// Install's last look before linking, by stat alone: a `wallspan` other than its own
    /// link means one already answers by name, however recently it arrived.
    static func installedElsewhere(
        shellHit: URL?,
        directories: [URL] = BinaryResolver.wellKnownDirectories,
        destination: URL = CommandLineTool.destination
    ) -> URL? {
        BinaryResolver.namedCandidates(shellHit: shellHit, directories: directories)
            .map(\.0)
            .first {
                $0.standardizedFileURL != destination.standardizedFileURL
                    && FileManager.default.isExecutableFile(atPath: $0.path)
            }
    }

    /// The `wallspan` a terminal would run, found without running anything: which binary
    /// the app itself runs is `BinaryResolver`'s question, and is answered by probing.
    struct Installed: Equatable {
        enum Origin: Equatable {
            /// The link `Install CLI…` leaves, still pointing into this bundle.
            case linkedByInstallCLI
            /// Into this bundle, but not by `Install CLI…`.
            case linkedToThisApp
            case homebrewFormula
            case homebrewCask
            /// The app bundle it lives in.
            case otherWallspanApp(URL)
            case elsewhere
        }

        enum PathStatus: Equatable {
            case first
            /// A terminal runs this other `wallspan` before it.
            case shadowedBy(URL)
            /// The login shell does not find it, or could not be asked.
            case notOnPath
        }

        let url: URL
        let origin: Origin
        let pathStatus: PathStatus
        /// The last resolution probed it and it did not answer `version --json`.
        let notWallspan: Bool

        /// Why the app runs something else, or nil when it runs this one.
        func unusedReason(resolution: BinaryResolver.Resolution, preferBundled: Bool) -> String? {
            guard !CommandLineTool.sameBinary(url, resolution.url) else { return nil }
            if preferBundled { return "PreferBundledCLI is set" }
            if let rejection = resolution.rejected.first(where: { Self.samePath($0.url, url) }) {
                return rejection.reason
            }
            return Self.foundSinceLaunch
        }

        static let foundSinceLaunch = "Found since launch; Look Again to use it"

        fileprivate static func samePath(_ a: URL, _ b: URL) -> Bool {
            a.standardizedFileURL == b.standardizedFileURL
        }
    }

    /// Stats candidates and never executes one, so it is safe to run on every menu open.
    /// What `resolution` learned by probing is borrowed, not refreshed.
    static func detect(
        shellHit: URL?,
        resolution: BinaryResolver.Resolution?,
        bundled: URL?,
        directories: [URL] = BinaryResolver.wellKnownDirectories,
        destination: URL = CommandLineTool.destination,
        ownBundle: URL = InstallSource.ownBundle,
        brewPrefixes: [String] = InstallSource.brewPrefixes
    ) -> Installed? {
        let found = BinaryResolver.namedCandidates(shellHit: shellHit, directories: directories)
            .map(\.0)
            .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
        func impostor(_ url: URL) -> Bool {
            resolution?.rejected.contains { Installed.samePath($0.url, url) && $0.notWallspan }
                ?? false
        }
        // Something else called `wallspan` first on PATH is reported only when no real one
        // stands behind it; otherwise the real one is, as shadowed.
        guard let url = found.first(where: { !impostor($0) }) ?? found.first else { return nil }

        let origin: Installed.Origin
        if Installed.samePath(url, destination),
           case .installed = state(bundled: bundled, at: destination) {
            origin = .linkedByInstallCLI
        } else if InstallSource.isCaskLink(url, brewPrefixes: brewPrefixes) {
            origin = .homebrewCask
        } else {
            switch InstallSource.cli(url, ownBundle: ownBundle, brewPrefixes: brewPrefixes) {
            case .bundledWithApp: origin = .linkedToThisApp
            case .homebrewFormula: origin = .homebrewFormula
            case .homebrewCask: origin = .homebrewCask
            case .other:
                origin = wallspanApp(containing: url).map { .otherWallspanApp($0) } ?? .elsewhere
            }
        }

        let pathStatus: Installed.PathStatus
        if let shellHit, found.contains(where: { Installed.samePath($0, shellHit) }) {
            pathStatus = sameBinary(url, shellHit) ? .first : .shadowedBy(shellHit)
        } else {
            pathStatus = .notOnPath
        }

        return Installed(url: url, origin: origin, pathStatus: pathStatus,
                         notWallspan: impostor(url))
    }

    /// The bundle a CLI resolves into, if it is the helper of some app.
    private static func wallspanApp(containing url: URL) -> URL? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasSuffix(".app/Contents/Helpers/wallspan") else { return nil }
        return resolved.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func sameBinary(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL
            == b.resolvingSymlinksInPath().standardizedFileURL
    }
}
