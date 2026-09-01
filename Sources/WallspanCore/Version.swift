// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

/// What this build calls itself. Reported by `wallspan version`, shown in the menu bar
/// app's About box, and carried in the `--json` contract.
///
/// Only `baseVersion` is hand-edited. Everything else comes from `BuildInfo.swift`, which
/// `Scripts/version.sh --stamp` rewrites in CI — so a release binary, a snapshot of main
/// and a PR build are told apart by the binary itself rather than by the filename it
/// happened to arrive in.
public enum Wallspan {
    /// The release this tree is working toward, bumped by hand right after a release. The
    /// release workflow refuses to tag a version that disagrees with it, which is what
    /// stops the bump being forgotten.
    public static let baseVersion = "0.1.0"

    /// The full version, including the channel and commit for anything but a release.
    /// Falls back to `baseVersion` in an unstamped working tree.
    public static var version: String {
        stampedVersion.isEmpty ? baseVersion : stampedVersion
    }
}
