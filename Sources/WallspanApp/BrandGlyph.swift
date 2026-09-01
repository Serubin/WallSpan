// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit

/// Drawn, not bundled: a SwiftPM `resources:` bundle is not copied into the app by
/// `make-app.sh`, so `NSImage(named:)` would return nil in the shipped bundle.
enum BrandGlyph {
    /// `brand/wallspan-menubar-template.svg`, y flipped for AppKit. The middle panel's y
    /// survives the flip only because it is vertically centred.
    private static let panels: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)] = [
        (0.8, 4.4, 4, 6.6),
        (5.9, 3.2, 5.2, 9.6),
        (12.2, 5.6, 3, 4.4),
    ]

    /// Puts 12pt of ink on the tall panel, matching `symbolConfiguration`: an icon that
    /// changes height with state reads as a rendering bug.
    private static let side: CGFloat = 20

    static let menuBar: NSImage = {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            // AppKit may draw into a rect that is not the nominal size.
            let k = rect.width / 16
            NSColor.black.setFill()
            for panel in panels {
                let frame = NSRect(x: rect.minX + panel.x * k, y: rect.minY + panel.y * k,
                                   width: panel.w * k, height: panel.h * k)
                NSBezierPath(roundedRect: frame, xRadius: k, yRadius: k).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Wallspan"
        return image
    }()

    /// Matches the glyph's 12pt ink; the inherited menu bar font draws 13.
    static let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
}
