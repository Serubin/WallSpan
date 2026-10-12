// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

// Rewritten in place by `Scripts/version.sh --stamp`, never by hand; checked in with an
// unstamped tree's values so that a bare `swift build` still compiles.
extension Wallspan {
    /// Empty in a working tree, so `version` falls back to `fallbackVersion`.
    static let stampedVersion = ""

    /// How this build was produced: `release`, `beta`, `unsigned`, `snapshot`, `dev`, or
    /// `local`.
    public static let channel = "local"

    /// Short commit the build came from; empty when it was not stamped.
    public static let commit = ""
}
