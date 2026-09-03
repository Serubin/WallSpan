// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit
import SwiftUI

/// What About shows.
struct AboutInfo {
    var appVersion: String?
    var copyright: String?
    var resolution: BinaryResolver.Resolution?
    /// From the agent report. Absent until one arrives — the app does not know where the
    /// log lives on its own, and guessing would be a second copy of that knowledge.
    var logPath: String?

    static func current(resolution: BinaryResolver.Resolution?, logPath: String?) -> AboutInfo {
        AboutInfo(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            copyright: Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright")
                as? String,
            resolution: resolution,
            logPath: logPath
        )
    }
}

/// Republished as the app learns things. Opening About right after launch — which
/// `--about` does — beats both the binary probe and the first agent report, and a window
/// that says "no wallspan found" until it is closed and reopened would be lying.
final class AboutModel: ObservableObject {
    @Published var info: AboutInfo

    init(info: AboutInfo) { self.info = info }
}

/// Hosts the About view. One window, since a second would be the same thing twice.
final class AboutWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: AboutModel?

    func show(info: AboutInfo) {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            model?.info = info
            window.makeKeyAndOrderFront(nil)
            return
        }

        let model = AboutModel(info: info)
        self.model = model

        let controller = NSHostingController(
            rootView: AboutView(model: model) { [weak self] in self?.window?.close() }
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "About Wallspan"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
    }

    /// Only while the window is up; About is not worth keeping a model alive for.
    func update(info: AboutInfo) {
        guard window != nil else { return }
        model?.info = info
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        model = nil
    }
}
