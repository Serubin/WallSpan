// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>
//
// The tools-version comment must stay on line 1 — SwiftPM reads it positionally — so the
// licence notice follows it rather than preceding it.
import PackageDescription

let package = Package(
    name: "wallspan",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure drawing, no wire types: the CLI's calibrate wallpaper and the app's overlay.
        .target(name: "CalibrationLattice"),
        .target(name: "WallspanCore", dependencies: ["CalibrationLattice"]),
        .executableTarget(name: "wallspan", dependencies: ["WallspanCore"]),
        // No contract types shared: the app parses the CLI's --json, and the two release apart.
        .executableTarget(
            // `Wallspan` would collide with `wallspan` in .build on a case-insensitive volume.
            name: "WallspanApp",
            dependencies: ["CalibrationLattice"]
        ),
    ]
)
