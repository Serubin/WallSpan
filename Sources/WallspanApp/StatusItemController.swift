// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit

/// The menu bar item. AppKit, not `MenuBarExtra`, which cannot render the thumbnail
/// header in `.menu` style and turns the menu into a popover in `.window` style.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private var resolution: BinaryResolver.Resolution?
    private var status: Contract.Status?
    private var agent: Contract.Agent?
    private var layout: Contract.Layout?
    private var lastFailure: String?
    /// Repair is attempted once per launch. A binary that cannot be re-pointed will not
    /// start working on the next poll, and retrying every 15s would restart the agent in a
    /// loop for as long as the app is open.
    private var didAttemptRepair = false

    /// Every CLI call runs here. Serial, so two menu clicks cannot interleave a `pause` and
    /// a `status` and render the earlier one's answer.
    private let queue = DispatchQueue(label: "net.serubin.wallspan.cli", qos: .userInitiated)
    private var refreshTimer: Timer?
    /// Faster polling only while the menu is open — the countdown is visible then, and
    /// invisible the rest of the time.
    private var menuIsOpen = false

    private static let intervals: [(String, String)] = [
        ("5 minutes", "5m"), ("15 minutes", "15m"), ("30 minutes", "30m"),
        ("1 hour", "1h"), ("4 hours", "4h"), ("1 day", "1d"),
    ]

    override init() {
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.image = NSImage(
            systemSymbolName: "photo.on.rectangle", accessibilityDescription: "Wallspan"
        )
        statusItem.button?.image?.isTemplate = true

        resolveBinary()
        refresh()
        scheduleRefresh(every: 15)
    }

    // MARK: - talking to the CLI

    private func resolveBinary() {
        queue.async { [weak self] in
            let resolved = BinaryResolver.resolve(
                preferBundled: UserDefaults.standard.bool(forKey: "PreferBundledCLI")
            )
            // Logged, not just shown in About: when the app is launched from a terminal
            // this is the fastest way to see which of several wallspans it settled on.
            let line: String
            if let resolved {
                line = "wallspan \(resolved.version.version) (schema \(resolved.version.schema))"
                    + " from \(resolved.source.rawValue): \(resolved.url.path)"
            } else {
                line = "no usable wallspan binary found"
            }
            FileHandle.standardError.write(Data((line + "\n").utf8))
            DispatchQueue.main.async {
                self?.resolution = resolved
                self?.refresh()
            }
        }
    }

    private func scheduleRefresh(every seconds: TimeInterval) {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func refresh() {
        guard let runner = resolution?.runner else { return }
        queue.async { [weak self] in
            let status = try? runner.status()
            let agent = try? runner.agent()
            let layout = try? runner.layout()
            DispatchQueue.main.async {
                self?.status = status
                self?.agent = agent
                self?.layout = layout
                self?.updateButton()
                self?.repairAgentIfBroken()
                if self?.menuIsOpen == true { self?.rebuild() }
            }
        }
    }

    /// Runs a subcommand, then refreshes. Failures surface as an alert rather than a silent
    /// no-op: a menu item that appears to do nothing is worse than an error.
    private func perform(_ arguments: [String], describing what: String) {
        guard let runner = resolution?.runner else { return }
        queue.async { [weak self] in
            var failure: String?
            do { try runner.run(arguments) } catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                if let failure { self?.report(failure, while: what) }
                self?.refresh()
            }
        }
    }

    private func report(_ message: String, while what: String) {
        lastFailure = message
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Could not \(what)"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - the button

    private func updateButton() {
        let symbol: String
        if resolution == nil {
            symbol = "exclamationmark.triangle"
        } else if status?.paused == true {
            symbol = "pause.circle"
        } else if status?.running == true {
            symbol = "photo.on.rectangle"
        } else {
            symbol = "photo"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Wallspan")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: - menu

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        rebuild()
        refresh()
        scheduleRefresh(every: 2)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        scheduleRefresh(every: 15)
    }

    private func item(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func rebuild() {
        menu.removeAllItems()

        guard let resolution else {
            menu.addItem(disabled("wallspan not found"))
            menu.addItem(.separator())
            menu.addItem(item("Look Again", #selector(lookAgain)))
            menu.addItem(item("About Wallspan…", #selector(showAbout)))
            menu.addItem(.separator())
            menu.addItem(item("Quit Wallspan", #selector(quit), key: "q"))
            return
        }

        addHeader()
        menu.addItem(.separator())

        // First, because Next and Pause below have nothing to act on without it.
        //
        // Titled from the agent, not `running`: this installs and removes the LaunchAgent,
        // while `running` can be a foreground `cycle` this button cannot stop.
        let running = status?.running == true
        let agentOn = agent?.loaded == true
        let cycling = item(agentOn ? "Disable Cycling" : "Enable Cycling", #selector(toggleAgent))
        if running, !agentOn {
            cycling.isEnabled = false
            cycling.toolTip = "A `wallspan cycle` running in a terminal is doing this. "
                + "Stop it there first."
        } else if !agentOn, status?.playlistDirectory == nil {
            cycling.isEnabled = false
            cycling.toolTip = "Choose a folder first."
        } else {
            cycling.toolTip = agentOn
                ? "Stops changing the wallpaper. Your folder and interval are kept."
                : "Changes the wallpaper on a schedule, and keeps doing it after you quit "
                  + "Wallspan and across logins."
        }
        menu.addItem(cycling)

        let next = item("Next Wallpaper", #selector(nextWallpaper))
        next.isEnabled = running
        menu.addItem(next)

        // Disabled rather than hidden when nothing is cycling: offering to pause something
        // that is not running is the state that read as a bug, but removing the row would
        // make the menu jump around as cycling comes and goes.
        let paused = status?.paused == true
        let toggle = item(paused ? "Resume Cycling" : "Pause Cycling", #selector(togglePause))
        toggle.isEnabled = running
        if !running { toggle.toolTip = "Nothing is cycling yet." }
        menu.addItem(toggle)

        menu.addItem(.separator())
        addPlaylistItems()
        menu.addItem(.separator())

        menu.addItem(item("Restore Original Wallpaper", #selector(restore)))
        menu.addItem(.separator())

        addSwitchBinaryItemIfUseful()

        let openAtLogin = item("Open Wallspan at Login", #selector(toggleLoginItem))
        switch LoginItem.state {
        case .on:
            openAtLogin.state = .on
        case .off:
            openAtLogin.state = .off
        case .needsApproval:
            openAtLogin.state = .mixed
            openAtLogin.title = "Open Wallspan at Login — approve in Settings"
        case .unavailable(let why):
            openAtLogin.isEnabled = false
            openAtLogin.toolTip = why
        }
        menu.addItem(openAtLogin)

        addDisplaysItem()
        addCommandLineToolItem()

        if agent?.logPath != nil {
            menu.addItem(item("Open Log", #selector(openLog)))
        }
        menu.addItem(.separator())
        menu.addItem(item("About Wallspan…", #selector(showAbout)))
        menu.addItem(item("Quit Wallspan", #selector(quit), key: "q"))
    }

    /// Shown when the agent is healthy but running a different binary than the app
    /// resolved. A menu item rather than a launch dialog: worth surfacing, not worth
    /// interrupting over.
    private func addSwitchBinaryItemIfUseful() {
        guard let resolution, let agent, agent.loaded, agent.programExists,
              let program = agent.program,
              URL(fileURLWithPath: program).standardizedFileURL != resolution.url.standardizedFileURL
        else { return }

        let item = item("Switch Background Cycling to This Copy", #selector(switchAgentBinary))
        item.toolTip = "Cycling currently runs \(program).\nThis app uses \(resolution.url.path)."
        menu.addItem(item)
    }

    private func addDisplaysItem() {
        guard let layout, !layout.displays.isEmpty else { return }
        let parent = NSMenuItem(title: "Displays", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for display in layout.displays {
            let line = "\(display.name) — \(display.pixelWidth)x\(display.pixelHeight)"
            let entry = disabled(display.densitySuspect ? "\(line)  ⚠︎" : line)
            if display.densitySuspect {
                entry.toolTip = "This panel reports a physical size implying non-square "
                    + "pixels, so an image may look slightly stretched. `wallspan layout "
                    + "size` sets the true dimensions."
            }
            submenu.addItem(entry)
        }
        if layout.displays.count > 1, !layout.calibrated {
            submenu.addItem(.separator())
            let note = disabled("Bezels not calibrated")
            note.toolTip = "Displays are treated as edge to edge, so a spanned image steps "
                + "across the gap. `wallspan calibrate` measures it."
            submenu.addItem(note)
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func addCommandLineToolItem() {
        guard let bundled = BinaryResolver.bundledBinary else { return }
        switch CommandLineTool.state(bundled: bundled) {
        case .installed:
            let entry = disabled("Command Line Tool Installed")
            entry.toolTip = CommandLineTool.destination.path
            menu.addItem(entry)
        case .notInstalled, .occupiedBy:
            menu.addItem(item("Install Command Line Tool…", #selector(installCommandLineTool)))
        }
    }

    private func addHeader() {
        guard let status else {
            menu.addItem(disabled("Loading…"))
            return
        }

        if let error = status.lastError {
            let item = disabled("⚠︎ \(error.prefix(80))")
            item.toolTip = error
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if let image = status.currentImage {
            menu.addItem(headerView(for: image, status: status))
        } else if status.playlistDirectory == nil {
            menu.addItem(disabled("No folder chosen yet"))
        } else {
            menu.addItem(disabled("Nothing applied yet"))
        }
    }

    /// Thumbnail plus two lines. A custom view because a menu item cannot otherwise carry
    /// an image at this size alongside two differently-styled lines.
    private func headerView(for path: String, status: Contract.Status) -> NSMenuItem {
        let url = URL(fileURLWithPath: path)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 52))

        let thumb = NSImageView(frame: NSRect(x: 14, y: 8, width: 60, height: 36))
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.image = NSImage(contentsOf: url)
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 3
        thumb.layer?.masksToBounds = true
        container.addSubview(thumb)

        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.frame = NSRect(x: 84, y: 26, width: 186, height: 16)
        name.font = .menuFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingMiddle
        container.addSubview(name)

        var parts: [String] = []
        if let position = status.position { parts.append(position) }
        if status.paused {
            parts.append("paused")
        } else if let next = status.nextAt {
            parts.append("next \(Self.relative(next))")
        } else if !status.running {
            parts.append("not cycling")
        }
        let detail = NSTextField(labelWithString: parts.joined(separator: " · "))
        detail.frame = NSRect(x: 84, y: 10, width: 186, height: 14)
        detail.font = .menuFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        container.addSubview(detail)

        let item = NSMenuItem()
        item.view = container
        item.toolTip = path
        return item
    }

    private func addPlaylistItems() {
        let folder = item(folderTitle(), #selector(chooseFolder))
        folder.toolTip = status?.playlistDirectory
        menu.addItem(folder)

        let intervalItem = NSMenuItem(title: "Change Every", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = status?.intervalSeconds ?? 900
        for (label, flag) in Self.intervals {
            let choice = NSMenuItem(title: label, action: #selector(setInterval(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = flag
            choice.state = (Self.seconds(flag) == current) ? .on : .off
            submenu.addItem(choice)
        }
        // A hand-set interval that matches none of the presets still has to be visible, or
        // the submenu silently misreports the schedule.
        if !Self.intervals.contains(where: { Self.seconds($0.1) == current }) {
            submenu.addItem(.separator())
            let custom = NSMenuItem(title: Self.describe(current), action: nil, keyEquivalent: "")
            custom.state = .on
            custom.isEnabled = false
            submenu.addItem(custom)
        }
        intervalItem.submenu = submenu
        menu.addItem(intervalItem)
    }

    private func folderTitle() -> String {
        guard let dir = status?.playlistDirectory else { return "Choose Folder…" }
        let name = URL(fileURLWithPath: dir).lastPathComponent
        switch status?.imageCount {
        case nil: return "Folder: \(name) — unreadable"
        case 0: return "Folder: \(name) — empty"
        case let count?: return "Folder: \(name) (\(count))"
        }
    }

    // MARK: - actions

    @objc private func nextWallpaper() { perform(["next"], describing: "change the wallpaper") }

    @objc private func togglePause() {
        let resuming = status?.paused == true
        perform([resuming ? "resume" : "pause"], describing: resuming ? "resume" : "pause")
    }

    @objc private func restore() {
        perform(["restore"], describing: "restore the original wallpaper")
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let flag = sender.representedObject as? String else { return }
        perform(["config", "set", "--interval", flag], describing: "change the interval")
    }

    @objc private func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder of wallpapers to cycle."
        // ~/Pictures is not TCC-protected, unlike Desktop, Documents and Downloads — and the
        // agent is a separate binary launchd spawns, so it cannot show a permission prompt
        // if it is denied. Steering the default here avoids the most common silent failure.
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first

        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(["config", "set", "--dir", url.path], describing: "set the folder")
    }

    @objc private func toggleAgent() {
        guard let resolution else { return }
        if agent?.loaded == true {
            perform(["agent", "uninstall"], describing: "stop background cycling")
        } else {
            // --binary, so launchd runs exactly the CLI this app resolved rather than a
            // staged copy that would drift from it.
            perform(["agent", "install", "--binary", resolution.url.path],
                    describing: "start background cycling")
        }
    }

    @objc private func openLog() {
        guard let path = agent?.logPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func lookAgain() {
        didAttemptRepair = false
        resolveBinary()
    }

    @objc private func switchAgentBinary() {
        guard let resolution else { return }
        perform(["agent", "install", "--binary", resolution.url.path],
                describing: "switch background cycling")
    }

    /// Re-points an agent whose binary has gone. Silent because there is no decision to
    /// put: the alternative is an agent launchd retries forever and never starts.
    private func repairAgentIfBroken() {
        guard !didAttemptRepair, let resolution, let agent,
              agent.program != nil, !agent.programExists
        else { return }
        didAttemptRepair = true

        let runner = resolution.runner
        let path = resolution.url.path
        queue.async { [weak self] in
            let repaired = (try? runner.run(["agent", "install", "--binary", path])) != nil
            FileHandle.standardError.write(Data((repaired
                ? "re-pointed the background agent at \(path)\n"
                : "background agent points at a missing binary and could not be repaired\n"
            ).utf8))
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    @objc private func toggleLoginItem() {
        if case .needsApproval = LoginItem.state {
            LoginItem.openSettings()
            return
        }
        let enabling = { if case .on = LoginItem.state { return false } else { return true } }()
        if let failure = LoginItem.set(enabling) {
            report(failure, while: enabling ? "open Wallspan at login" : "stop opening at login")
        }
        rebuild()
    }

    @objc private func installCommandLineTool() {
        guard let bundled = BinaryResolver.bundledBinary else { return }
        NSApp.activate(ignoringOtherApps: true)

        var replacing = false
        if case .occupiedBy(let existing) = CommandLineTool.state(bundled: bundled) {
            let alert = NSAlert()
            alert.messageText = "Replace the wallspan already at that path?"
            alert.informativeText = "\(CommandLineTool.destination.path)\ncurrently points at "
                + "\(existing.path)."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            replacing = true
        }

        if let failure = CommandLineTool.install(bundled: bundled, replacing: replacing) {
            report(failure, while: "install the command line tool")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Installed"
        alert.informativeText = CommandLineTool.isOnPath()
            ? "`wallspan` is now on your PATH. Try `wallspan status`."
            : "Linked into \(CommandLineTool.destinationDirectory.path), which is not on "
              + "your PATH yet. Add it to your shell profile to use `wallspan` by name."
        alert.runModal()
        rebuild()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Wallspan"

        var lines: [String] = []
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        lines.append("App \(appVersion ?? "development build")")
        if let resolution {
            lines.append("CLI \(resolution.version.version) (schema \(resolution.version.schema))")
            lines.append("Using the copy from \(resolution.source.rawValue):")
            lines.append(resolution.url.path)
            for (url, reason) in resolution.rejected {
                lines.append("Skipped \(url.path) — \(reason)")
            }
        } else {
            lines.append("No usable wallspan binary was found.")
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - formatting

    static func seconds(_ flag: String) -> Double {
        let units: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
        guard let last = flag.last, let multiplier = units[last],
              let n = Double(flag.dropLast()) else { return Double(flag) ?? 0 }
        return n * multiplier
    }

    static func describe(_ seconds: Double) -> String {
        if seconds >= 86400 { return "Every \(Int(seconds / 86400)) days" }
        if seconds >= 3600 { return "Every \(Int(seconds / 3600)) hours" }
        if seconds >= 60 { return "Every \(Int(seconds / 60)) minutes" }
        return "Every \(Int(seconds)) seconds"
    }

    /// Coarse on purpose: a menu refreshed every two seconds that claims "in 7m 43s" is
    /// wrong before the eye reaches the end of it.
    static func relative(_ date: Date) -> String {
        let d = date.timeIntervalSinceNow
        if d <= 30 { return "any moment" }
        if d < 3600 { return "in \(Int((d / 60).rounded()))m" }
        return "in \(String(format: "%.1f", d / 3600))h"
    }
}
