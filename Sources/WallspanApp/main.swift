// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit

/// Menu bar front-end for the `wallspan` CLI.
///
/// It spawns the CLI and renders its `--json` output; it holds no wallpaper, layout or
/// playlist logic of its own, and links none. See `docs/cli-json-contract.md`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusItemController()
        self.controller = controller
        // `--calibrate` opens the calibration window straight away, without going through
        // the menu. It is the only way to reach that window from a script, which is what
        // makes it testable at all — a menu item cannot be clicked from a terminal.
        if CommandLine.arguments.contains("--calibrate") {
            controller.showCalibration()
        }
        // Same reason: the About window carries the binary-resolution diagnostics, and a
        // menu item cannot be clicked from a terminal.
        if CommandLine.arguments.contains("--about") {
            controller.showAbout()
        }
    }
}

// Before anything is put in the menu bar: a second status item is the visible symptom,
// but the real hazard is two of them pausing and resuming cycling independently.
guard SingleInstance.claim() else {
    FileHandle.standardError.write(Data("Wallspan is already running\n".utf8))
    exit(0)
}

let app = NSApplication.shared
// No Dock icon and no menu bar of its own. Also set in the bundle's Info.plist as
// LSUIElement, but stated here too so `swift run` behaves the same as the built app.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
