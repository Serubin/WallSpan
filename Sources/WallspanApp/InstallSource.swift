// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import Foundation

/// How a copy of Wallspan got onto the disk, which decides what "update it" means. A
/// Homebrew install pointed at a zip would be overwritten again on the next `brew upgrade`.
enum InstallSource: Equatable {
    /// Which cask token installed it. A fixed set, so the command shown never carries a
    /// name read off the disk.
    enum Track: CaseIterable, Equatable {
        case stable
        case beta

        var caskToken: String {
            switch self {
            case .stable: return "wallspan"
            case .beta: return "wallspan@beta"
            }
        }
    }

    /// The CLI inside the app bundle, or the symlink `Install CLI…` leaves pointing at it.
    /// Its upgrade path is the app's.
    case bundledWithApp
    /// Stable only: Homebrew cannot load a formula whose name has `@` before a non-digit.
    case homebrewFormula
    case homebrewCask(Track)
    /// A zip, a hand build, or a copy someone put on PATH themselves.
    case other

    var upgradeCommand: String? {
        switch self {
        case .homebrewFormula: return "brew upgrade wallspan"
        case .homebrewCask(let track): return "brew upgrade --cask \(track.caskToken)"
        case .bundledWithApp, .other: return nil
        }
    }

    /// Installed by the `wallspan@beta` cask, whose upgrades include betas.
    var followsBetas: Bool { self == .homebrewCask(.beta) }

    /// The two prefixes a Finder-launched app can find. An exotic `HOMEBREW_PREFIX` is
    /// invisible here — launchd gives the app no shell environment — so it reads as
    /// `.other` and gets the release page, which is wrong but harmless.
    static let brewPrefixes = ["/opt/homebrew", "/usr/local"]

    static var ownBundle: URL {
        Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Resolved in full rather than one hop: Homebrew's link is relative
    /// (`../Cellar/wallspan/0.1.0/bin/wallspan`), and `Install CLI…` adds a second hop.
    static func cli(_ url: URL, ownBundle: URL = InstallSource.ownBundle,
                    brewPrefixes: [String] = InstallSource.brewPrefixes) -> InstallSource {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        if resolved.path.hasPrefix(ownBundle.path + "/") { return .bundledWithApp }
        if let track = caskLinkTrack(url, brewPrefixes: brewPrefixes) {
            return .homebrewCask(track)
        }

        let parts = resolved.pathComponents
        if let cellar = parts.firstIndex(of: "Cellar"), parts.count > cellar + 1,
           parts[cellar + 1] == "wallspan" { return .homebrewFormula }
        return .other
    }

    static func isCaskLink(_ url: URL,
                           brewPrefixes: [String] = InstallSource.brewPrefixes) -> Bool {
        caskLinkTrack(url, brewPrefixes: brewPrefixes) != nil
    }

    /// Judged by where the link sits and one hop of where it points, not by the running
    /// bundle: the cask links into the Wallspan.app it installed, which need not be this one.
    static func caskLinkTrack(_ url: URL,
                              brewPrefixes: [String] = InstallSource.brewPrefixes) -> Track? {
        let directory = url.deletingLastPathComponent()
        guard let prefix = brewPrefixes.map({ URL(fileURLWithPath: $0) }).first(where: {
                  $0.appendingPathComponent("bin").standardizedFileURL.path
                      == directory.standardizedFileURL.path
              }),
              let hop = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        else { return nil }

        let target = URL(fileURLWithPath: hop, relativeTo: directory).standardizedFileURL
        for track in Track.allCases {
            let room = caskroom(track, under: prefix).standardizedFileURL
            if target.path.hasPrefix(room.path + "/") { return track }
        }
        guard target.path.hasSuffix("/Wallspan.app/Contents/Helpers/wallspan") else { return nil }
        let app = target.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return caskTrack(installing: app, under: prefix, orOnlyCaskroom: true)
    }

    /// A Caskroom entry proves a cask is installed, not that it is the bundle now running —
    /// so the link is resolved and compared, with the install location as a weaker fallback
    /// for the versions of Homebrew that copy instead.
    static func app(_ bundle: URL = InstallSource.ownBundle,
                    brewPrefixes: [String] = InstallSource.brewPrefixes,
                    installedAt: String = "/Applications/Wallspan.app") -> InstallSource {
        for prefix in brewPrefixes.map({ URL(fileURLWithPath: $0) }) {
            if let track = caskTrack(installing: bundle, under: prefix,
                                     orOnlyCaskroom: bundle.path == installedAt) {
                return .homebrewCask(track)
            }
        }
        return .other
    }

    private static func caskroom(_ track: Track, under prefix: URL) -> URL {
        prefix.appendingPathComponent("Caskroom").appendingPathComponent(track.caskToken)
    }

    /// The cask whose Caskroom links to `app`. Failing that, and only when asked, the one
    /// cask installed: with both present, the bundle alone cannot say which owns it.
    private static func caskTrack(installing app: URL, under prefix: URL,
                                  orOnlyCaskroom: Bool) -> Track? {
        let want = app.resolvingSymlinksInPath().standardizedFileURL.path
        var installed: [Track] = []
        for track in Track.allCases {
            guard let versions = try? FileManager.default.contentsOfDirectory(
                at: caskroom(track, under: prefix), includingPropertiesForKeys: nil
            ) else { continue }
            installed.append(track)
            let linked = versions.contains {
                $0.appendingPathComponent("Wallspan.app")
                    .resolvingSymlinksInPath().standardizedFileURL.path == want
            }
            if linked { return track }
        }
        return orOnlyCaskroom && installed.count == 1 ? installed[0] : nil
    }
}
