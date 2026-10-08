// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import CoreGraphics
import Foundation
import SwiftUI

/// State and lifecycle for the calibration window. The judging happens on the screens, so
/// the overlay must never wait for the CLI to catch up.
final class CalibrationModel: ObservableObject {
    /// What the CLI last reported, with every nudge it has not answered yet laid over it.
    @Published private(set) var layout: Contract.Layout?
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    @Published var selectedUUID: String?
    @Published var stepPx: Double = 1

    /// A panel's origin shift, in that panel's pixels — the unit `layout nudge` takes.
    private struct Shift {
        var dx = 0.0, dy = 0.0

        /// Below what any screen can show; also keeps a no-op from reaching the CLI, which
        /// refuses a nudge with neither axis.
        var isNegligible: Bool { abs(dx) < 0.01 && abs(dy) < 0.01 }

        static func + (a: Shift, b: Shift) -> Shift { Shift(dx: a.dx + b.dx, dy: a.dy + b.dy) }
    }

    /// An edit not yet sent. Kept in order: the CLI converts a nudge's pixels at the density
    /// current when it runs, so a nudge and a scale do not commute.
    private enum Pending {
        case nudge(String, Shift)
        /// Multiplicative, so a held ⌥-arrow coalesces into one `--scale`.
        case scale(String, Double)
    }

    private let runner: CLIRunner
    private let queue = DispatchQueue(label: "net.serubin.wallspan.calibrate", qos: .userInitiated)

    private var confirmed: Contract.Layout?
    /// Sent and not yet answered, by call; a reply covers its own call and every one before.
    private var inFlight: [Int: (uuid: String, shift: Shift)] = [:]
    private var pending: [Pending] = []
    private var drag: (uuid: String, shift: Shift)?
    private var nextCall = 0
    /// The call that failed. Its error stands until a call made after it succeeds, so the
    /// resync it triggers cannot hide why the screens snapped back.
    private var failedCall: Int?
    /// Nudge and scale calls outstanding. Coalescing holds new ones back until this is zero.
    private var coalescedOutstanding = 0
    private var busyOutstanding = 0

    /// Whether *this window* paused cycling, and so owes a resume. A pause the user set
    /// themselves must survive the window closing.
    private var didPause = false
    private var closed = false

    init(runner: CLIRunner) {
        self.runner = runner
    }

    var displays: [Contract.Display] { layout?.displays ?? [] }

    var selected: Contract.Display? {
        displays.first { $0.uuid == selectedUUID } ?? displays.first
    }

    /// Calibration adjusts the space *between* panels, so one panel has nothing to adjust.
    var canCalibrate: Bool { displays.count >= 2 }

    /// The panel whose picture holds still. An older CLI does not say, so fall back to the
    /// rule it applies: the main display, else the first.
    var anchorUUID: String? {
        let uuids = Set(displays.map(\.uuid))
        if let reported = layout?.anchorUUID, uuids.contains(reported) { return reported }
        if let main = uuidForDisplay(CGMainDisplayID()), uuids.contains(main) { return main }
        return displays.first?.uuid
    }

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
        exclusive { runner in
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
            self.confirm(layout)
            if self.selectedUUID == nil { self.selectedUUID = layout.displays.first?.uuid }
        }
    }

    /// Sends every edit still queued before resuming: the user saw it on screen, so it is
    /// what they expect saved. `waiting` blocks until that is done, for quitting.
    func close(waiting: Bool = false) {
        guard !closed else { return }
        endDrag()
        sendAllQueued()
        closed = true

        let runner = self.runner
        let resume = didPause
        queue.async {
            if resume { try? runner.run(["resume"]) }
        }
        if waiting { queue.sync {} }
    }

    /// Re-reads the layout, for when the screens changed under it.
    func refresh() {
        resync(clearingFailure: true)
    }

    private func resync(clearingFailure: Bool) {
        exclusive(clearingFailure: clearingFailure) { runner in
            try runner.layout()
        } then: { [weak self] in self?.confirm($0) }
    }

    // MARK: - adjusting

    /// Moves the *picture*, in pixels of the selected display, y-up. Shown at once; the CLI
    /// hears about it as soon as it is free.
    func nudge(dx: Double, dy: Double) {
        guard canCalibrate, let uuid = selected?.uuid else { return }
        enqueue(nudge: uuid, panelShift(dx: dx, dy: dy))
        republish()
        sendNext()
    }

    /// Grabbing a panel selects it. Returns whether dragging it should move the picture:
    /// moving the anchor moves every *other* picture, so it could never follow the cursor.
    func beginDrag(on uuid: String) -> Bool {
        endDrag()
        selectedUUID = uuid
        guard canCalibrate, uuid != anchorUUID else { return false }
        drag = (uuid, Shift())
        return true
    }

    /// `dx`/`dy` are the total since the drag began, as `nudge` takes them.
    func dragTo(dx: Double, dy: Double) {
        guard let uuid = drag?.uuid else { return }
        drag = (uuid, panelShift(dx: dx, dy: dy))
        republish()
    }

    /// Commits a drag as one nudge. Safe to call with no drag in progress.
    func endDrag() {
        guard let drag else { return }
        self.drag = nil
        enqueue(nudge: drag.uuid, drag.shift)
        republish()
        sendNext()
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

    /// Nudges the density itself. Not previewed: a resize also moves the panels beside it,
    /// which only the CLI knows how to do.
    func scaleBy(percent: Double) {
        guard let uuid = selected?.uuid else { return }
        enqueue(scale: uuid, by: 1 + percent / 100)
        sendNext()
    }

    func reset() {
        edit(["layout", "reset"])
    }

    // MARK: - the macOS arrangement

    /// What arranging would do, without doing it. Feeds the confirmation.
    func planArrange(_ finish: @escaping (Contract.Arrange?) -> Void) {
        exclusive { runner in
            try runner.json(Contract.Arrange.self, key: "arrange",
                            ["layout", "arrange", "--dry-run"])
        } then: { finish($0) }
    }

    /// Permanently rewrites the macOS display arrangement, so it is only ever called after
    /// the user has seen the plan and said yes.
    func applyArrange(_ finish: @escaping (Contract.Arrange?) -> Void) {
        exclusive { runner in
            try runner.json(Contract.Arrange.self, key: "arrange", ["layout", "arrange"],
                            timeout: 60)
        } then: { [weak self] report in
            self?.refresh()
            finish(report)
        }
    }

    func revertArrange(_ finish: @escaping (Contract.Arrange?) -> Void) {
        exclusive { runner in
            try runner.json(Contract.Arrange.self, key: "arrange",
                            ["layout", "arrange", "--revert"], timeout: 60)
        } then: { [weak self] report in
            self?.refresh()
            finish(report)
        }
    }

    // MARK: - pending edits

    /// Negated because raising a panel samples a higher slice, which reads as the picture
    /// sliding down.
    private func panelShift(dx: Double, dy: Double) -> Shift { Shift(dx: -dx, dy: -dy) }

    /// The confirmed layout with every unanswered shift applied, using the CLI's own
    /// conversion — `layout nudge` is a pure origin shift, so this is exact, not a guess.
    private func republish() {
        guard var shown = confirmed else {
            layout = nil
            return
        }
        var total: [String: Shift] = [:]
        func add(_ uuid: String, _ s: Shift) { total[uuid] = (total[uuid] ?? Shift()) + s }
        for call in inFlight.values { add(call.uuid, call.shift) }
        for case .nudge(let uuid, let s) in pending { add(uuid, s) }
        if let drag { add(drag.uuid, drag.shift) }

        shown.displays = shown.displays.map { d in
            guard let s = total[d.uuid] else { return d }
            var moved = d
            moved.originMM = [d.originX + s.dx / d.densityX, d.originY + s.dy / d.densityY]
            return moved
        }
        layout = shown
    }

    private func confirm(_ reply: Contract.Layout) {
        confirmed = reply
        republish()
    }

    /// Joins the last pending edit when it is the same kind on the same panel, so coalescing
    /// never reorders.
    private func enqueue(nudge uuid: String, _ shift: Shift) {
        if case .nudge(uuid, let prior)? = pending.last {
            pending[pending.count - 1] = .nudge(uuid, prior + shift)
        } else {
            pending.append(.nudge(uuid, shift))
        }
    }

    private func enqueue(scale uuid: String, by factor: Double) {
        if case .scale(uuid, let prior)? = pending.last {
            pending[pending.count - 1] = .scale(uuid, prior * factor)
        } else {
            pending.append(.scale(uuid, factor))
        }
    }

    /// At most one coalesced call in flight: a held arrow key or a burst of drags becomes a
    /// handful of calls rather than one per event, with no timer.
    private func sendNext() {
        guard !closed, coalescedOutstanding == 0 else { return }
        sendOneQueued()
    }

    /// Sends the oldest pending edit, ignoring the in-flight limit. False when none is left.
    @discardableResult
    private func sendOneQueued() -> Bool {
        while !pending.isEmpty {
            switch pending.removeFirst() {
            case .nudge(let uuid, let shift):
                guard !shift.isNegligible else { continue }
                var args = ["layout", "nudge", uuid]
                if abs(shift.dx) >= 0.01 { args += ["--dx", "\(shift.dx)px"] }
                if abs(shift.dy) >= 0.01 { args += ["--dy", "\(shift.dy)px"] }
                send(args, carrying: (uuid, shift))
            case .scale(let uuid, let factor):
                guard abs(factor - 1) >= 1e-5 else { continue }
                send(["layout", "size", uuid, "--scale", String(format: "%.4f", factor * 100)],
                     carrying: nil)
            }
            return true
        }
        return false
    }

    private func sendAllQueued() {
        while sendOneQueued() {}
    }

    private func send(_ args: [String], carrying shift: (uuid: String, shift: Shift)?) {
        let call = beginCall()
        if let shift { inFlight[call] = shift }
        coalescedOutstanding += 1

        let runner = self.runner
        queue.async { [weak self] in
            let outcome = Result { try runner.json(Contract.Layout.self, key: "layout", args) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.coalescedOutstanding -= 1
                // Replies arrive in call order, so this one covers every earlier call too.
                self.inFlight = self.inFlight.filter { $0.key > call }
                switch outcome {
                case .success(let layout):
                    self.succeeded(call)
                    self.confirm(layout)
                    self.sendNext()
                case .failure(let error):
                    self.dropPending(after: error, in: call)
                }
            }
        }
    }

    /// What is on screen can no longer be trusted to match the config, so throw away what
    /// has not been sent and re-read rather than replaying edits against an unknown state.
    private func dropPending(after error: Error, in call: Int) {
        failed(call, error)
        pending = []
        republish()
        resync(clearingFailure: false)
    }

    /// Edits that are not coalesced go out behind every queued nudge, so they land in the
    /// order they were made.
    private func edit(_ arguments: [String]) {
        exclusive { runner in
            try runner.json(Contract.Layout.self, key: "layout", arguments)
        } then: { [weak self] in self?.confirm($0) }
    }

    // MARK: - plumbing

    private func beginCall() -> Int {
        defer { nextCall += 1 }
        return nextCall
    }

    private func succeeded(_ call: Int) {
        guard call > (failedCall ?? -1) else { return }
        failure = nil
        failedCall = nil
    }

    private func failed(_ call: Int, _ error: Error) {
        failure = error.localizedDescription
        failedCall = call
    }

    /// One-off calls that show as busy. Queued edits go first, on the same serial queue.
    private func exclusive<T>(
        clearingFailure: Bool = true,
        _ work: @escaping (CLIRunner) throws -> T,
        then finish: @escaping (T) -> Void
    ) {
        sendAllQueued()
        let call = beginCall()
        busyOutstanding += 1
        busy = true
        let runner = self.runner
        queue.async { [weak self] in
            let outcome = Result { try work(runner) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busyOutstanding -= 1
                self.busy = self.busyOutstanding > 0
                switch outcome {
                case .success(let value):
                    if clearingFailure { self.succeeded(call) }
                    finish(value)
                case .failure(let error):
                    self.failed(call, error)
                }
            }
        }
    }
}

/// The identifier the CLI reports displays by, matching how macOS keys its own wallpaper
/// store.
func uuidForDisplay(_ id: CGDirectDisplayID) -> String? {
    guard let ref = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
    return CFUUIDCreateString(nil, ref.takeRetainedValue()) as String?
}
