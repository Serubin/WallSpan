// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit

/// The menu bar item. AppKit, not `MenuBarExtra`, which cannot render the thumbnail
/// header in `.menu` style and turns the menu into a popover in `.window` style.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private var resolution: BinaryResolver.Resolution?
    /// Separates "still probing" from "probed, found nothing", which the button renders
    /// differently.
    private var didResolve = false
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
    /// One controller for the life of the app, so two calibration windows cannot both be
    /// pausing and resuming cycling.
    private let calibration = CalibrationWindowController()
    private let about = AboutWindowController()
    private let updates = UpdateChecker()
    /// `resolveBinary` runs again for "Look Again", which must not re-arm the check.
    private var didArmUpdateChecks = false
    private var updateTimer: Timer?
    private var updateCheckInFlight = false
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
        // Otherwise AppKit re-enables every item whose target answers its action, after
        // `rebuild()` has run, and each `isEnabled = false` below is silently undone.
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateButton()

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
                line = "wallspan \(resolved.version.summary)"
                    + " from \(resolved.source.rawValue): \(resolved.url.path)"
            } else {
                line = "no usable wallspan binary found"
            }
            FileHandle.standardError.write(Data((line + "\n").utf8))
            DispatchQueue.main.async {
                self?.didResolve = true
                self?.resolution = resolved
                // Before refresh(), which returns early when nothing resolved.
                self?.updateButton()
                self?.updateAbout()
                self?.refresh()
                self?.armUpdateChecks()
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
                self?.updateAbout()
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
        guard let button = statusItem.button else { return }

        let image: NSImage?
        let dimmed: Bool
        let label: String
        if didResolve, resolution == nil {
            image = symbol("exclamationmark.triangle")
            dimmed = false
            label = "Wallspan, no command line tool found"
        } else if status?.paused == true {
            image = symbol("pause.circle")
            dimmed = false
            label = "Wallspan, paused"
        } else {
            // Dimmed by AppKit, not a fainter glyph: the menu bar is translucent over the
            // wallpaper this app changes, so a fixed alpha has no reliable contrast.
            image = BrandGlyph.menuBar
            dimmed = status?.running != true
            label = dimmed ? "Wallspan, not cycling" : "Wallspan, cycling"
        }
        button.image = image
        button.appearsDisabled = dimmed
        // On the button, not the shared glyph; dimming alone is silent to VoiceOver.
        button.setAccessibilityLabel(label)
    }

    /// Pinned to the glyph's point size, so the icon does not change size with state.
    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Wallspan")?
            .withSymbolConfiguration(BrandGlyph.symbolConfiguration)
        image?.isTemplate = true
        return image
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

        guard resolution != nil else {
            menu.addItem(disabled("wallspan not found"))
            menu.addItem(.separator())
            menu.addItem(item("Look Again", #selector(lookAgain)))
            // Offered here too: a broken install is exactly when an update is worth knowing
            // about, and this branch is where a broken install lands.
            addUpdateItems()
            menu.addItem(item("About Wallspan…", #selector(openAbout)))
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

        addUpdateItems()
        menu.addItem(item("About Wallspan…", #selector(openAbout)))
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
        submenu.addItem(.separator())
        let calibrate = item("Calibrate…", #selector(openCalibration))
        // Offered on a single display too: the window explains why there is nothing to
        // calibrate, and correcting a wrong panel size there is still worthwhile.
        calibrate.toolTip = layout.displays.count < 2
            ? "Needs two or more displays to measure a bezel gap."
            : "Line the picture up across the bezels."
        submenu.addItem(calibrate)
        parent.submenu = submenu
        menu.addItem(parent)
    }

    @objc private func openCalibration() { showCalibration() }

    /// Also the entry point for `--calibrate`. Waits for resolution rather than giving up:
    /// at launch the binary probe has usually not finished yet.
    func showCalibration(retriesLeft: Int = 20) {
        guard let runner = resolution?.runner else {
            guard retriesLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.showCalibration(retriesLeft: retriesLeft - 1)
            }
            return
        }
        calibration.show(runner: runner)
    }

    /// Offered only when there is nothing to reach `wallspan` by. A CLI already resolved
    /// from PATH or a standard location — Homebrew's formula, say — is the thing this item
    /// would install, and linking a second copy over it would only be a way to end up
    /// running the wrong one.
    private func addCommandLineToolItem() {
        guard let bundled = BinaryResolver.bundledBinary else { return }

        let installed: String?
        switch CommandLineTool.state(bundled: bundled) {
        case .installed:
            installed = CommandLineTool.destination.path
        case .notInstalled, .occupiedBy:
            // Resolved from anywhere but the bundle means `wallspan` already answers by
            // name, whoever put it there.
            installed = resolution.flatMap { $0.source == .bundled ? nil : $0.url.path }
        }

        guard let path = installed else {
            menu.addItem(item("Install CLI…", #selector(installCommandLineTool)))
            return
        }
        let entry = disabled("CLI Installed")
        entry.toolTip = "wallspan is already installed at \(path)"
        menu.addItem(entry)
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
            report(failure, while: "install the CLI")
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

    @objc private func openAbout() { showAbout() }

    private func updateAbout() {
        about.update(info: .current(resolution: resolution, logPath: agent?.logPath))
    }

    /// Also the entry point for `--about`. Opens immediately even at launch, before the
    /// binary probe and the first agent report land; `refresh` fills the window in.
    func showAbout() {
        about.show(info: .current(resolution: resolution, logPath: agent?.logPath))
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - updates

    /// Once per launch, five seconds after the binary resolves — at login the network is
    /// frequently not up yet — plus a re-arm for a Mac that is never restarted.
    private func armUpdateChecks() {
        guard !didArmUpdateChecks else { return }
        didArmUpdateChecks = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkForUpdatesQuietly()
        }
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdatesQuietly()
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    /// The automatic path never alerts, whatever the answer: offline, rate limited and
    /// already up to date are all things nobody asked to hear about.
    private func checkForUpdatesQuietly() {
        guard updates.automatic else { return }
        updates.check(force: false, against: .current(resolution: resolution)) {
            [weak self] outcome in
            if case .available(let offer) = outcome {
                UpdateChecker.log("wallspan \(offer.latest) is available")
            }
            if self?.menuIsOpen == true { self?.rebuild() }
        }
    }

    /// Computed from the last tag seen and the *current* resolution, never stored — which
    /// is what lets "Look Again" recompute the entry with no second request.
    private func currentOffer() -> UpdateOffer? {
        guard let tag = updates.lastSeenTag else { return nil }
        return UpdateOffer.make(tag: tag, builds: .current(resolution: resolution))
    }

    private func addUpdateItems() {
        menu.addItem(.separator())

        if let offer = currentOffer() {
            let entry = item("Update Available — \(offer.latest)", #selector(openUpdate))
            entry.toolTip = offer.commands.isEmpty
                ? "Opens the release page. Right now \(offer.behind)."
                : "Homebrew installed this, so upgrade it there: "
                    + offer.commands.joined(separator: ", ")
            menu.addItem(entry)
        }

        let check = item(updateCheckInFlight ? "Checking for Updates…" : "Check for Updates…",
                         #selector(checkForUpdatesNow))
        check.isEnabled = !updateCheckInFlight
        menu.addItem(check)

        let automatic = item("Check for Updates Automatically",
                             #selector(toggleAutomaticUpdates))
        automatic.state = updates.automatic ? .on : .off
        automatic.toolTip = "One unauthenticated request to GitHub's releases endpoint, at "
            + "most once a day. Nothing is sent about you or this machine."
        menu.addItem(automatic)

        menu.addItem(.separator())
    }

    /// The entry point for `--check-updates`, which exists for the same reason `--about`
    /// does. Waits for the probe, since the comparison has no basis until it lands.
    func checkForUpdates(retriesLeft: Int = 20) {
        guard didResolve else {
            guard retriesLeft > 0 else {
                return UpdateChecker.log("gave up waiting for the binary probe to finish")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.checkForUpdates(retriesLeft: retriesLeft - 1)
            }
            return
        }
        checkForUpdatesNow()
    }

    @objc private func checkForUpdatesNow() {
        updateCheckInFlight = true
        if menuIsOpen { rebuild() }
        updates.check(force: true, against: .current(resolution: resolution)) {
            [weak self] outcome in
            guard let self else { return }
            updateCheckInFlight = false
            if menuIsOpen { rebuild() }
            announce(outcome)
        }
    }

    @objc private func toggleAutomaticUpdates() {
        updates.automatic.toggle()
        rebuild()
        // An explicit yes deserves an answer now — but through the gated path, so it does
        // not make a second request if a check already succeeded today.
        if updates.automatic { checkForUpdatesQuietly() }
    }

    @objc private func openUpdate() {
        guard let offer = currentOffer() else { return }
        offerUpdate(offer)
    }

    /// A manual check always ends in something visible. "Fail silent" governs the automatic
    /// path only; here `perform(_:describing:)`'s reasoning applies instead.
    private func announce(_ outcome: UpdateChecker.Outcome) {
        switch outcome {
        case .available(let offer):
            offerUpdate(offer)
        case .upToDate(let latest):
            inform("You're up to date.", "\(latest) is the latest release.")
        case .ahead(let latest):
            inform("You're ahead of the latest release.",
                   "This build is newer than \(latest).")
        case .failed(let why):
            report(why, while: "check for updates")
        case .skipped:
            inform("Nothing to compare.", "This looks like a development build, so there "
                   + "is no released version to measure it against.")
        }
    }

    /// A Homebrew install is given the command rather than a zip that `brew upgrade` would
    /// overwrite on its next run. Anything else opens the page, which is the whole answer.
    private func offerUpdate(_ offer: UpdateOffer) {
        guard !offer.commands.isEmpty else {
            NSWorkspace.shared.open(offer.releaseURL)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Wallspan \(offer.latest) is available"
        alert.informativeText = "Right now \(offer.behind). Homebrew installed it, so "
            + "upgrade it there:\n\n" + offer.commands.joined(separator: "\n")
        alert.addButton(withTitle: offer.commands.count > 1 ? "Copy Commands" : "Copy Command")
        alert.addButton(withTitle: "Release Notes…")
        alert.addButton(withTitle: "Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(offer.commands.joined(separator: "\n"),
                                           forType: .string)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(offer.releaseURL)
        default:
            break
        }
    }

    private func inform(_ message: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

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
