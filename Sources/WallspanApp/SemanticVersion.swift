// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import Foundation

/// A version with semver precedence, which is not the same as comparing the strings:
/// `0.2.0-snapshot.10` is newer than `0.2.0-snapshot.7`, and both are older than `0.2.0`.
struct SemanticVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    /// Dot-separated identifiers; empty for a release. Build metadata (`+g1a2b3c4`) is
    /// parsed only to be dropped — semver gives it no part in precedence, which is the
    /// only reason this build's own `0.2.0-snapshot.7+g1a2b3c4` is comparable to anything.
    let prerelease: [String]

    /// A leading `v` is accepted, so a git tag can be handed over exactly as it arrives.
    init?(_ raw: String) {
        var rest = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if rest.first == "v" { rest = rest.dropFirst() }
        if let plus = rest.firstIndex(of: "+") { rest = rest[..<plus] }

        var tail: Substring = ""
        if let dash = rest.firstIndex(of: "-") {
            tail = rest[rest.index(after: dash)...]
            rest = rest[..<dash]
        }

        let core = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3, let major = Int(core[0]), let minor = Int(core[1]),
              let patch = Int(core[2]), major >= 0, minor >= 0, patch >= 0
        else { return nil }

        self.major = major
        self.minor = minor
        self.patch = patch
        prerelease = tail.isEmpty ? [] : tail.split(separator: ".").map(String.init)
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        // A release outranks every prerelease of the same core, which is what makes
        // `0.2.0-snapshot.7 < 0.2.0` and `0.3.0-snapshot.4 > 0.2.0` both come out right.
        if a.prerelease.isEmpty || b.prerelease.isEmpty {
            return !a.prerelease.isEmpty && b.prerelease.isEmpty
        }
        for (left, right) in zip(a.prerelease, b.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            // ASCII order over the legal charset, which is the order semver asks for.
            case (nil, nil): return left < right
            }
        }
        return a.prerelease.count < b.prerelease.count
    }

    /// Gates every tag before it reaches a URL or a menu title. One arrives over the
    /// network and one from a user-writable plist, and they are the only untrusted strings
    /// in this path.
    static func isPlausibleTag(_ tag: String) -> Bool {
        guard tag.count <= 32, SemanticVersion(tag) != nil else { return false }
        // `isASCII` first: `isLetter` alone admits most of Unicode, and this string is
        // about to be interpolated into a URL path.
        return tag.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "+")
        }
    }
}
