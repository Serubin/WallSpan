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
        .target(name: "WallspanCore"),
        .executableTarget(name: "wallspan", dependencies: ["WallspanCore"]),
    ]
)
