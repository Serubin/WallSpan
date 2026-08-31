// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit
import SwiftUI

/// The calibration controls. Small on purpose: what is being judged is on the screens
/// behind it, so this must not become the thing being looked at.
struct CalibrationView: View {
    @ObservedObject var model: CalibrationModel
    var onDone: () -> Void

    @FocusState private var keyboardFocused: Bool

    private static let steps: [Double] = [1, 2, 5, 10, 20, 50]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PanelDiagram(displays: model.displays, selected: model.selected?.uuid)
                .frame(height: 110)
                .accessibilityLabel("Physical arrangement of your displays")

            if model.canCalibrate {
                controls
                gaps
            } else {
                singleDisplayNotice
                sizeFields
            }

            Divider()
            footer
        }
        .padding(18)
        .frame(width: 460)
        // The window is driven by the arrow keys, so it has to hold focus without the user
        // clicking into a field first.
        .focusable()
        .focused($keyboardFocused)
        .onAppear { keyboardFocused = true }
        .onKeyPress(.leftArrow) { nudge(dx: -model.stepPx) }
        .onKeyPress(.rightArrow) { nudge(dx: model.stepPx) }
        .onKeyPress(.upArrow) { nudge(dy: model.stepPx) }
        .onKeyPress(.downArrow) { nudge(dy: -model.stepPx) }
    }

    private func nudge(dx: Double = 0, dy: Double = 0) -> KeyPress.Result {
        guard model.canCalibrate else { return .ignored }
        model.nudge(dx: dx, dy: dy)
        return .handled
    }

    // MARK: - pieces

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Display", selection: displaySelection) {
                    ForEach(model.displays) { Text($0.name).tag($0.uuid) }
                }
                .frame(maxWidth: 240)

                Spacer()

                Picker("Step", selection: $model.stepPx) {
                    ForEach(Self.steps, id: \.self) { Text("\(Int($0)) px").tag($0) }
                }
                .frame(width: 120)
            }

            HStack(spacing: 12) {
                arrowPad
                VStack(alignment: .leading, spacing: 6) {
                    Text("Arrow keys move the picture on the selected display.")
                        .font(.callout)
                    Text("Diagonals breaking across the bezel mean the position is off. "
                         + "Circles breaking while the diagonals line up mean the scale is — "
                         + "use Panel scale below, no nudge can fix it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            sizeFields
        }
    }

    private var displaySelection: Binding<String> {
        Binding(
            get: { model.selected?.uuid ?? "" },
            set: { model.selectedUUID = $0 }
        )
    }

    private var arrowPad: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            GridRow {
                Color.clear.frame(width: 28, height: 24)
                arrow("chevron.up") { model.nudge(dx: 0, dy: model.stepPx) }
                Color.clear.frame(width: 28, height: 24)
            }
            GridRow {
                arrow("chevron.left") { model.nudge(dx: -model.stepPx, dy: 0) }
                arrow("chevron.down") { model.nudge(dx: 0, dy: -model.stepPx) }
                arrow("chevron.right") { model.nudge(dx: model.stepPx, dy: 0) }
            }
        }
    }

    private func arrow(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 28, height: 24)
        }
        .buttonStyle(.bordered)
    }

    private var sizeFields: some View {
        Group {
            if let display = model.selected {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Panel scale").frame(width: 78, alignment: .leading)
                        Button("−") { model.scaleBy(percent: -0.1) }
                            .help("0.1% smaller")
                        PPIField(value: display.ppi) { model.setPPI($0) }
                        Button("+") { model.scaleBy(percent: 0.1) }
                            .help("0.1% larger")
                        Text("PPI").font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.1f × %.1f mm", display.widthMM, display.heightMM))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if display.sizeWasCorrected, display.reportedSizeMM.count > 1 {
                        Text(String(format: "Panel reports %.1f × %.1f mm; corrected to square"
                                    + " pixels.", display.reportedSizeMM[0],
                                    display.reportedSizeMM[1]))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if display.densitySuspect {
                        Text("Still non-square — set the real size with `layout size`.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var gaps: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(model.layout?.gaps ?? []) { gap in
                HStack {
                    Text("\(gap.left)  |  \(gap.right)")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(model.gapDescription(gap))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(gap.gapMM < 0.05 ? .secondary : .primary)
                }
            }
            if model.layout?.calibrated == false {
                Text("Not measured yet — panels are treated as edge to edge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var singleDisplayNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Calibration needs two or more displays.")
                .font(.callout.weight(.medium))
            Text("Bezel calibration measures the gap between panels, so there is nothing to "
                 + "adjust with one. Correcting a wrong panel size below is still worth doing "
                 + "— it matters as soon as you attach a second display.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button("Reset", action: model.reset)
                .disabled(model.busy)
                .help("Back to edge-to-edge, seeded from what each display reports.")

            if model.patternStale || model.busy {
                ProgressView().controlSize(.small)
                Text(model.patternStale ? "Updating screens…" : "Working…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.canCalibrate {
                Button("Align in System Settings…", action: confirmArrange)
                    .disabled(model.busy)
                    .help("Push the calibrated vertical offsets into the macOS display "
                          + "arrangement, which decides where the cursor crosses between "
                          + "screens.")
            }
            Button("Done", action: onDone).keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - arranging

    /// Asks first, alone among the controls here: this rewrites macOS's own arrangement,
    /// which `layout reset` cannot undo. Shows deltas and residuals, not "are you sure".
    private func confirmArrange() {
        model.planArrange { plan in
            guard let plan else { return }
            guard !plan.targets.isEmpty, plan.targets.contains(where: { $0.delta != 0 }) else {
                notice("Nothing to align",
                       plan.targets.isEmpty
                           ? "Arranging moves displays relative to the main one, so it needs "
                             + "a second display."
                           : "The macOS arrangement already matches your calibration.")
                return
            }

            var body = plan.targets.map { target -> String in
                let sign = target.delta >= 0 ? "+" : ""
                var line = "\(target.name): move \(sign)\(target.delta) pt"
                if target.hasResidual {
                    line += String(format: "\n    %+.1f pt of density mismatch remains at the "
                                   + "top of the overlap, %+.1f at the bottom",
                                   target.residualTopPt, target.residualBottomPt)
                }
                return line
            }.joined(separator: "\n")

            if plan.targets.contains(where: { $0.hasResidual }) {
                body += "\n\nPanels of differing density cannot agree at every height, so "
                    + "that remainder can only be centred, not removed."
            }
            body += "\n\nThis changes your macOS display arrangement permanently."

            let alert = NSAlert()
            alert.messageText = "Align displays vertically?"
            alert.informativeText = body
            alert.addButton(withTitle: "Align")
            alert.addButton(withTitle: "Cancel")
            if plan.canRevert { alert.addButton(withTitle: "Revert to Saved") }

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                model.applyArrange { done in
                    guard done?.applied == true else { return }
                    notice("Aligned", "Your previous arrangement was saved. Reopen this "
                           + "window and choose Revert to Saved to put it back.")
                }
            case .alertThirdButtonReturn:
                model.revertArrange { _ in
                    notice("Reverted", "The arrangement macOS had before wallspan touched "
                           + "it has been restored.")
                }
            default:
                break
            }
        }
    }

    private func notice(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    private func format(_ mm: Double) -> String {
        // Trailing zeros on a step of "1 mm" read as false precision; a gap of 14.25 needs
        // the decimals. Two places, trimmed.
        String(format: "%.2f", mm)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
}

/// Commits on Return or focus loss, never per keystroke — each commit is a CLI call and a
/// re-render of the desktop.
private struct PPIField: View {
    let value: Double
    let commit: (Double) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .frame(width: 64)
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .onSubmit(send)
            .onChange(of: focused) { _, isFocused in if !isFocused { send() } }
            .onAppear { text = String(format: "%.2f", value) }
            // A scale step rewrites the field, but not while it is being typed in.
            .onChange(of: value) { _, new in
                if !focused { text = String(format: "%.2f", new) }
            }
    }

    private func send() {
        guard let entered = Double(text.trimmingCharacters(in: .whitespaces)), entered > 1,
              abs(entered - value) > 0.001
        else {
            text = String(format: "%.2f", value)
            return
        }
        commit(entered)
    }
}

/// The panels drawn to scale with the calibrated gaps between them, so a wrong number is
/// visible as a wrong picture before the test pattern is even looked at.
private struct PanelDiagram: View {
    let displays: [Contract.Display]
    let selected: String?

    var body: some View {
        Canvas { context, size in
            let rects = displays.map {
                CGRect(x: $0.originX, y: $0.originY, width: $0.widthMM, height: $0.heightMM)
            }
            guard let union = rects.dropFirst().reduce(rects.first, { $0?.union($1) }),
                  union.width > 0, union.height > 0
            else { return }

            let inset: CGFloat = 8
            let scale = min((size.width - inset * 2) / union.width,
                            (size.height - inset * 2) / union.height)
            let originX = (size.width - union.width * scale) / 2
            let originY = (size.height - union.height * scale) / 2

            for (display, rect) in zip(displays, rects) {
                // y is flipped: the layout is y-up in millimetres, the canvas is y-down.
                let drawn = CGRect(
                    x: originX + (rect.minX - union.minX) * scale,
                    y: originY + (union.maxY - rect.maxY) * scale,
                    width: rect.width * scale,
                    height: rect.height * scale
                )
                let path = Path(roundedRect: drawn, cornerRadius: 3)
                let isSelected = display.uuid == selected
                context.fill(path, with: .color(isSelected ? .accentColor.opacity(0.28)
                                                           : .secondary.opacity(0.12)))
                context.stroke(path, with: .color(isSelected ? .accentColor : .secondary),
                               lineWidth: isSelected ? 2 : 1)

                if drawn.width > 46 {
                    context.draw(
                        Text(display.name).font(.system(size: 9)).foregroundStyle(.secondary),
                        at: CGPoint(x: drawn.midX, y: drawn.midY)
                    )
                }
            }
        }
    }
}
