// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

// Overwritten in place by `Scripts/version.sh --stamp`; the values below are what an
// unstamped working tree reports. Checked in rather than generated so that a bare
// `swift build` still compiles — hand-edit `baseVersion` in Version.swift, not this file.
extension Wallspan {
    /// Empty in a working tree, so `version` falls back to `baseVersion`.
    static let stampedVersion = ""

    /// How this build was produced: `release`, `snapshot`, `dev`, or `local`.
    public static let channel = "local"

    /// Short commit the build came from; empty when it was not stamped.
    public static let commit = ""
}
