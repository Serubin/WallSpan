// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit
import SwiftUI

/// Hosts the calibration view and the overlay it drives. One instance only — two would both
/// pause and resume cycling, and the second to close would resume what the first still owned.
final class CalibrationWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: CalibrationModel?
    private var overlay: CalibrationOverlay?

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
        // The overlay covers every window, so these controls must sit above it, on every Space
        // the overlay follows.
        window.level = CalibrationLevel.controls
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.window = window

        // Clicking a screen activates the app; the arrow keys need this window to be key.
        overlay = CalibrationOverlay(model: model) { [weak self] in self?.focusControls() }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.open()
    }

    private func focusControls() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    /// Quitting never closes the window, so the queued edits and the resume would be lost.
    func prepareForTermination() {
        model?.close(waiting: true)
    }

    /// Covers the close button, Done, and the window being closed any other way — all of
    /// them have to save what the screens show and return cycling to how it was found.
    func windowWillClose(_ notification: Notification) {
        model?.close()
        overlay?.tearDown()
        overlay = nil
        model = nil
        window?.delegate = nil
        window = nil
    }
}
