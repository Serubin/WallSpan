// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import Foundation

/// How a copy of Wallspan got onto the disk, which decides what "update it" means. A
/// Homebrew install pointed at a zip would be overwritten again on the next `brew upgrade`.
enum InstallSource {
    /// The CLI inside the app bundle, or the symlink `Install CLI…` leaves pointing at it.
    /// Its upgrade path is the app's.
    case bundledWithApp
    case homebrewFormula
    case homebrewCask
    /// A zip, a hand build, or a copy someone put on PATH themselves.
    case other

    var upgradeCommand: String? {
        switch self {
        case .homebrewFormula: return "brew upgrade wallspan"
        case .homebrewCask: return "brew upgrade --cask wallspan"
        case .bundledWithApp, .other: return nil
        }
    }

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
        if isCaskLink(url, brewPrefixes: brewPrefixes) { return .homebrewCask }

        let parts = resolved.pathComponents
        if let cellar = parts.firstIndex(of: "Cellar"), parts.count > cellar + 1,
           parts[cellar + 1] == "wallspan" { return .homebrewFormula }
        return .other
    }

    /// Judged by where the link sits and one hop of where it points, not by the running
    /// bundle: the cask links into the Wallspan.app it installed, which need not be this one.
    static func isCaskLink(_ url: URL,
                           brewPrefixes: [String] = InstallSource.brewPrefixes) -> Bool {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        guard let prefix = brewPrefixes.map({ URL(fileURLWithPath: $0) }).first(where: {
                  $0.appendingPathComponent("bin").standardizedFileURL.path
                      == directory.standardizedFileURL.path
              }),
              let hop = try? fm.destinationOfSymbolicLink(atPath: url.path)
        else { return false }

        let room = prefix.appendingPathComponent("Caskroom/wallspan").standardizedFileURL
        let target = URL(fileURLWithPath: hop, relativeTo: directory).standardizedFileURL
        if target.path.hasPrefix(room.path + "/") { return true }
        var isDirectory: ObjCBool = false
        return target.path.hasSuffix("/Wallspan.app/Contents/Helpers/wallspan")
            && fm.fileExists(atPath: room.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// A Caskroom entry proves a cask is installed, not that it is the bundle now running —
    /// so the link is resolved and compared, with the install location as a weaker fallback
    /// for the versions of Homebrew that copy instead.
    static func app() -> InstallSource {
        let me = ownBundle
        for prefix in brewPrefixes {
            let room = URL(fileURLWithPath: prefix).appendingPathComponent("Caskroom/wallspan")
            guard let versions = try? FileManager.default.contentsOfDirectory(
                at: room, includingPropertiesForKeys: nil
            ) else { continue }

            for version in versions {
                let linked = version.appendingPathComponent("Wallspan.app")
                    .resolvingSymlinksInPath().standardizedFileURL
                if linked == me { return .homebrewCask }
            }
            if me.path == "/Applications/Wallspan.app" { return .homebrewCask }
        }
        return .other
    }
}
