// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit
import CalibrationLattice
import Combine

/// Window levels during calibration: the pattern over every app window and the Dock, below
/// the menu bar, and the controls above the pattern.
enum CalibrationLevel {
    static let overlay = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
    static let controls = NSWindow.Level(rawValue: overlay.rawValue + 1)
}

/// Draws the calibration lattice over every screen, in front of every window, without
/// touching the wallpaper.
final class CalibrationOverlay {
    private let model: CalibrationModel
    private let onGrab: () -> Void
    private var windows: [String: OverlayWindow] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var screenObserver: NSObjectProtocol?

    /// `onGrab` runs when a screen is clicked, to hand the keyboard back to the controls.
    init(model: CalibrationModel, onGrab: @escaping () -> Void) {
        self.model = model
        self.onGrab = onGrab

        // Published fires before the property changes, so read the model a turn later.
        model.$layout.map { _ in () }
            .merge(with: model.$selectedUUID.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.sync() }
            .store(in: &subscriptions)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuild()
            self?.model.refresh()
        }
    }

    func tearDown() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        subscriptions.removeAll()
        windows.values.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    /// Screens and placements disagree after a hotplug until the next reply, so a
    /// mismatch in either direction rebuilds.
    private func sync() {
        let wanted = Set(NSScreen.screens.compactMap(\.displayUUID))
            .intersection(model.displays.map(\.uuid))
        if wanted != Set(windows.keys) { return rebuild() }
        for (uuid, window) in windows { window.overlayView.scene = scene(for: uuid) }
    }

    private func rebuild() {
        // A window going away mid-drag never sees its mouse-up.
        model.endDrag()
        windows.values.forEach { $0.orderOut(nil) }
        windows.removeAll()

        for screen in NSScreen.screens {
            guard let uuid = screen.displayUUID, let scene = scene(for: uuid) else { continue }
            let window = OverlayWindow(screen: screen, model: model, onGrab: onGrab)
            window.overlayView.scene = scene
            window.orderFrontRegardless()
            windows[uuid] = window
        }
    }

    private func scene(for uuid: String) -> OverlayView.Scene? {
        guard let display = model.displays.first(where: { $0.uuid == uuid }),
              let anchor = model.displays.first(where: { $0.uuid == model.anchorUUID })
        else { return nil }
        return OverlayView.Scene(
            display: display,
            // From the anchor's *current* placement, so nudging it moves the lattice with it.
            anchorMM: CGPoint(x: anchor.originX + anchor.widthMM / 2,
                              y: anchor.originY + anchor.heightMM / 2),
            isAnchor: uuid == anchor.uuid,
            isSelected: uuid == model.selected?.uuid,
            canCalibrate: model.canCalibrate
        )
    }
}

/// Borderless, and never key: the controls window must keep the keyboard, or the arrow keys
/// die the moment the overlay appears.
private final class OverlayWindow: NSWindow {
    let overlayView: OverlayView

    init(screen: NSScreen, model: CalibrationModel, onGrab: @escaping () -> Void) {
        overlayView = OverlayView(model: model, onGrab: onGrab)
        // Global coordinates, as `NSScreen.frame` reports them.
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered,
                   defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = CalibrationLevel.overlay
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary,
                              .ignoresCycle]
        overlayView.menuBarInset = screen.frame.maxY - screen.visibleFrame.maxY
        contentView = overlayView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One panel's view of the lattice. Not flipped: y-up, like the millimetre space it draws.
private final class OverlayView: NSView {
    struct Scene: Equatable {
        var display: Contract.Display
        var anchorMM: CGPoint
        var isAnchor: Bool
        var isSelected: Bool
        var canCalibrate: Bool

        var canDrag: Bool { canCalibrate && !isAnchor }
    }

    /// Only a changed panel redraws: a drag publishes at the mouse's rate.
    var scene: Scene? {
        didSet { if scene != oldValue { needsDisplay = true } }
    }
    var menuBarInset: CGFloat = 0

    private weak var model: CalibrationModel?
    private let onGrab: () -> Void
    private var dragStart: NSPoint?

    private static let scrimAlpha: CGFloat = 0.85

    init(model: CalibrationModel, onGrab: @escaping () -> Void) {
        self.model = model
        self.onGrab = onGrab
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        ctx.setFillColor(CalibrationLattice.backdrop.copy(alpha: Self.scrimAlpha)
                         ?? CalibrationLattice.backdrop)
        ctx.fill(bounds)

        guard let scene else { return }
        let d = scene.display
        guard d.widthMM > 0, d.heightMM > 0 else { return }

        // The same mapping a wallpaper slice gets in `SpanRenderer.drawRect`.
        let ptPerMMX = bounds.width / d.widthMM, ptPerMMY = bounds.height / d.heightMM
        let backing = window?.backingScaleFactor ?? 1
        ctx.saveGState()
        ctx.scaleBy(x: ptPerMMX, y: ptPerMMY)
        ctx.translateBy(x: -d.originX, y: -d.originY)
        CalibrationLattice.draw(
            in: ctx,
            extentMM: CGRect(x: d.originX, y: d.originY, width: d.widthMM, height: d.heightMM),
            anchorMM: scene.anchorMM,
            minLineMM: 1 / (max(ptPerMMX, ptPerMMY) * backing)
        )
        ctx.restoreGState()

        if scene.isSelected {
            let border = NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3))
            border.lineWidth = 6
            NSColor.controlAccentColor.setStroke()
            border.stroke()
        }
        drawLabel(scene)
    }

    private func drawLabel(_ scene: Scene) {
        var text = scene.display.name
        if scene.isAnchor { text += " — reference, held still" }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let label = NSAttributedString(string: text, attributes: attributes)
        let size = label.size()
        let pill = NSRect(x: 20, y: bounds.maxY - menuBarInset - 20 - size.height - 8,
                          width: size.width + 20, height: size.height + 8)
        let fill = scene.isSelected ? NSColor.controlAccentColor
                                    : NSColor.black.withAlphaComponent(0.55)
        fill.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        label.draw(at: NSPoint(x: pill.minX + 10, y: pill.minY + 4))
    }

    // MARK: - grabbing

    /// The first click on an inactive app still grabs, rather than only activating it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways,
                                                              .inVisibleRect],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        (scene?.canDrag == true ? NSCursor.openHand : NSCursor.arrow).set()
    }

    override func mouseDown(with event: NSEvent) {
        guard let scene, let model else { return }
        onGrab()
        if model.beginDrag(on: scene.display.uuid) {
            dragStart = event.locationInWindow
            NSCursor.closedHand.set()
        }
    }

    /// Window positions, y-up like the picture; in backing pixels, the unit `layout nudge`
    /// takes.
    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let model else { return }
        let backing = window?.backingScaleFactor ?? 1
        let p = event.locationInWindow
        model.dragTo(dx: Double((p.x - dragStart.x) * backing),
                     dy: Double((p.y - dragStart.y) * backing))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        model?.endDrag()
        NSCursor.openHand.set()
    }
}

extension NSScreen {
    /// The UUID the CLI reports this screen's display by.
    var displayUUID: String? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .flatMap { uuidForDisplay($0.uint32Value) }
    }
}
