// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit
import SwiftUI

/// Hosts the calibration view. One instance only — two would both pause and resume
/// cycling, and the second to close would resume what the first still owned.
final class CalibrationWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: CalibrationModel?

    func show(runner: CLIRunner) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let model = CalibrationModel(runner: runner)
        self.model = model

        let controller = NSHostingController(
            rootView: CalibrationView(model: model) { [weak self] in self?.close() }
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "Calibrate Displays"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        // Above the desktop but not above everything: the user is looking past this window
        // at the pattern, and may want another app in front of it.
        window.level = .normal
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.open()
    }

    func close() {
        window?.close()
    }

    /// Covers the close button, Done, and the window being closed any other way — all of
    /// them have to return cycling to how it was found.
    func windowWillClose(_ notification: Notification) {
        model?.close()
        model = nil
        window?.delegate = nil
        window = nil
    }
}
