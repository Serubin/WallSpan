// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import Foundation
import SwiftUI

/// State and lifecycle for the calibration window. The judging happens on the screens, so
/// the numbers must never wait for the desktop to catch up.
final class CalibrationModel: ObservableObject {
    @Published private(set) var layout: Contract.Layout?
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    @Published var selectedUUID: String?
    @Published var stepPx: Double = 1

    /// Set when the pattern on screen is behind the numbers, so the view can say so rather
    /// than looking frozen.
    @Published private(set) var patternStale = false

    private let runner: CLIRunner
    private let queue = DispatchQueue(label: "net.serubin.wallspan.calibrate", qos: .userInitiated)
    private var applyWork: DispatchWorkItem?

    /// Whether *this window* paused cycling, and so owes a resume. A pause the user set
    /// themselves must survive the window closing.
    private var didPause = false
    private var closed = false

    /// Long enough that a held arrow key coalesces into one render; short enough that a
    /// single nudge feels immediate. Each apply is a full re-render of the union at panel
    /// density, so this is the difference between one and thirty of them.
    private static let applyDebounce: TimeInterval = 0.3

    init(runner: CLIRunner) {
        self.runner = runner
    }

    var displays: [Contract.Display] { layout?.displays ?? [] }

    var selected: Contract.Display? {
        displays.first { $0.uuid == selectedUUID } ?? displays.first
    }

    /// Calibration adjusts the space *between* panels, so one panel has nothing to adjust.
    var canCalibrate: Bool { displays.count >= 2 }

    /// A horizontal gap, read in pixels of the panel on its left. Two panels of differing
    /// density disagree on what a pixel is worth, so it is measured against one of them.
    func gapDescription(_ gap: Contract.Gap) -> String {
        guard let left = displays.first(where: { $0.uuid == gap.leftUUID }) else {
            return String(format: "%.1f mm", gap.gapMM)
        }
        return String(format: "%.0f px", gap.gapMM * left.densityX)
    }

    // MARK: - lifecycle

    func open() {
        run { runner in
            // Read before writing: this is the only chance to learn the pre-existing pause
            // state, and pausing first would destroy the answer.
            let status = try? runner.status()
            let wasPaused = status?.paused ?? false
            let running = status?.running ?? false
            if running, !wasPaused { try? runner.run(["pause"]) }
            let layout = try runner.layout()
            return (layout, running && !wasPaused)
        } then: { [weak self] layout, paused in
            guard let self else { return }
            self.didPause = paused
            self.layout = layout
            if self.selectedUUID == nil { self.selectedUUID = layout.displays.first?.uuid }
            self.applyPattern(immediately: true)
        }
    }

    /// Runs regardless of what is still in flight: leaving cycling paused because a render
    /// was mid-apply when the window closed would be a worse bug than a wasted render.
    func close() {
        guard !closed else { return }
        closed = true
        applyWork?.cancel()

        let runner = self.runner
        let resume = didPause
        queue.async {
            if resume { try? runner.run(["resume"]) }
        }
    }

    // MARK: - adjusting

    /// Moves the *picture*, in pixels of the selected display. Negated because raising a
    /// panel samples a higher slice, which reads as the picture sliding down.
    func nudge(dx: Double, dy: Double) {
        guard let uuid = selected?.uuid else { return }
        var args = ["layout", "nudge", uuid]
        if dx != 0 { args += ["--dx", "\(-dx)px"] }
        if dy != 0 { args += ["--dy", "\(-dy)px"] }
        edit(args)
    }

    func setSize(width: Double, height: Double) {
        guard let uuid = selected?.uuid else { return }
        edit(["layout", "size", uuid, "--width", "\(width)mm", "--height", "\(height)mm"])
    }

    /// The second calibration axis. Offset makes the diagonals meet; scale makes the
    /// circles meet, and no nudge can substitute for it — a scale error grows with distance
    /// from wherever the panels happen to agree.
    func setPPI(_ ppi: Double) {
        guard let uuid = selected?.uuid, ppi > 1 else { return }
        edit(["layout", "size", uuid, "--ppi", String(format: "%.3f", ppi)])
    }

    /// Nudges the density itself, which is easier to converge by eye than typing a figure.
    func scaleBy(percent: Double) {
        guard let uuid = selected?.uuid else { return }
        edit(["layout", "size", uuid, "--scale", String(format: "%.4f", 100 + percent)])
    }

    func reset() {
        edit(["layout", "reset"])
    }

    // MARK: - the macOS arrangement

    /// What arranging would do, without doing it. Feeds the confirmation.
    func planArrange(_ finish: @escaping (Contract.Arrange?) -> Void) {
        run { runner in
            try runner.json(Contract.Arrange.self, key: "arrange",
                            ["layout", "arrange", "--dry-run"])
        } then: { finish($0) }
    }

    /// Permanently rewrites the macOS display arrangement, so it is only ever called after
    /// the user has seen the plan and said yes.
    func applyArrange(_ finish: @escaping (Contract.Arrange?) -> Void) {
        run { runner in
            try runner.json(Contract.Arrange.self, key: "arrange", ["layout", "arrange"],
                            timeout: 60)
        } then: { [weak self] report in
            // Moving displays changes the union, so the pattern is now drawn for a layout
            // that no longer exists.
            self?.applyPattern(immediately: true)
            finish(report)
        }
    }

    func revertArrange(_ finish: @escaping (Contract.Arrange?) -> Void) {
        run { runner in
            try runner.json(Contract.Arrange.self, key: "arrange",
                            ["layout", "arrange", "--revert"], timeout: 60)
        } then: { [weak self] report in
            self?.applyPattern(immediately: true)
            finish(report)
        }
    }

    /// Applies the edit, publishes the layout it returns, and schedules the desktop to
    /// catch up. The numbers and gap readouts move now; only the pattern waits.
    private func edit(_ arguments: [String]) {
        patternStale = true
        run { runner in
            try runner.json(Contract.Layout.self, key: "layout", arguments)
        } then: { [weak self] layout in
            self?.layout = layout
            self?.applyPattern(immediately: false)
        }
    }

    private func applyPattern(immediately: Bool) {
        guard canCalibrate || immediately else {
            patternStale = false
            return
        }
        applyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performApply() }
        applyWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (immediately ? 0 : Self.applyDebounce), execute: work
        )
    }

    private func performApply() {
        let runner = self.runner
        queue.async { [weak self] in
            let layout = try? runner.json(Contract.Layout.self, key: "layout", ["calibrate"],
                                          timeout: 60)
            DispatchQueue.main.async {
                guard let self else { return }
                if let layout { self.layout = layout }
                self.patternStale = false
            }
        }
    }

    // MARK: - plumbing

    private func run<T>(
        _ work: @escaping (CLIRunner) throws -> T,
        then finish: @escaping (T) -> Void
    ) {
        busy = true
        let runner = self.runner
        queue.async { [weak self] in
            let outcome = Result { try work(runner) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch outcome {
                case .success(let value):
                    self.failure = nil
                    finish(value)
                case .failure(let error):
                    self.failure = error.localizedDescription
                }
            }
        }
    }
}
