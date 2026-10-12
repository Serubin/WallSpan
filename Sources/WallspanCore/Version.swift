// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

/// What this build calls itself. Reported by `wallspan version`, shown in the menu bar
/// app's About box, and carried in the `--json` contract.
///
/// It all comes from `BuildInfo.swift`, which `Scripts/version.sh --stamp` rewrites in CI —
/// so a release binary, a snapshot of main and a PR build are told apart by the binary
/// itself rather than by the filename it happened to arrive in.
public enum Wallspan {
    /// What an unstamped working tree reports. Release versions are chosen when the release
    /// workflow is dispatched, never written into the source.
    public static let fallbackVersion = "0.0.0-local"

    /// The full version: `-beta.N`, `-rc.N` or `-unsigned.N` for a prerelease, and the
    /// channel and commit for a snapshot or dev build. Falls back to `fallbackVersion` in an
    /// unstamped working tree.
    public static var version: String {
        stampedVersion.isEmpty ? fallbackVersion : stampedVersion
    }
}
