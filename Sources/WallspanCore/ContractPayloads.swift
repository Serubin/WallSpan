// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit

/// Payloads for the `--json` contract. Deliberately flat DTOs rather than the internal
/// types they are built from: `PhysicalLayout` and friends are free to be reshaped, and a
/// front-end pinned to an older release must keep parsing. Renaming a field here is a
/// breaking change; adding one is not.
public enum Contract {}

extension Contract {
    public struct VersionReport: Codable {
        public var version: String
        public var schema: Int
        /// Lets a front-end feature-detect without a schema bump — the mechanism that
        /// makes "additive changes do not bump" workable for a caller older than the CLI.
        public var commands: [String]

        public init(version: String, schema: Int, commands: [String]) {
            self.version = version
            self.schema = schema
            self.commands = commands
        }
    }

    public struct RectReport: Codable {
        public var x: Double, y: Double, width: Double, height: Double

        public init(_ r: CGRect) {
            x = Double(r.minX); y = Double(r.minY)
            width = Double(r.width); height = Double(r.height)
        }
    }

    public struct DisplayReport: Codable {
        public var uuid: String
        public var name: String
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var scale: Double
        /// Logical frame in the macOS arrangement, y-up points.
        public var framePoints: RectReport
        /// Calibrated active area, y-up millimetres.
        public var originMM: [Double]
        public var sizeMM: [Double]
        public var pxPerMMX: Double
        public var pxPerMMY: Double
        /// EDID implies non-square pixels, so `layout size` is worth running. The same
        /// condition `layout show` flags in prose.
        public var densitySuspect: Bool

        init(display d: DisplayInfo, placement p: Placement) {
            let dx = Double(CGFloat(d.pixelWidth) / p.sizeMM.width)
            let dy = Double(CGFloat(d.pixelHeight) / p.sizeMM.height)
            uuid = p.uuid
            name = p.name
            pixelWidth = d.pixelWidth
            pixelHeight = d.pixelHeight
            scale = Double(d.scale)
            framePoints = RectReport(d.frame)
            originMM = [Double(p.originMM.x), Double(p.originMM.y)]
            sizeMM = [Double(p.sizeMM.width), Double(p.sizeMM.height)]
            pxPerMMX = dx
            pxPerMMY = dy
            densitySuspect = abs(dx - dy) > 0.02
        }
    }

    public struct GapReport: Codable {
        public var left: String
        public var right: String
        /// The names are for display; these are what a caller nudges. Two identical
        /// monitors report the same name, so the names alone cannot identify a panel.
        public var leftUUID: String
        public var rightUUID: String
        public var gapMM: Double
    }

    /// What `layout arrange` would do, or did. Vertical only — macOS forces displays
    /// contiguous. The residuals matter most: differing densities cannot fully agree.
    public struct ArrangeReport: Codable {
        public struct Target: Codable {
            public var uuid: String
            public var name: String
            public var currentY: Int
            public var requestedY: Int
            public var delta: Int
            public var residualTopPt: Double
            public var residualBottomPt: Double
        }

        public var targets: [Target]
        /// False for `--dry-run`, and when everything already matched.
        public var applied: Bool
        /// A saved arrangement exists, so `--revert` has somewhere to go back to.
        public var canRevert: Bool

        public init(targets: [DisplayArranger.Target], applied: Bool, canRevert: Bool) {
            self.targets = targets.map {
                Target(uuid: $0.uuid, name: $0.display.name,
                       currentY: $0.currentYDown, requestedY: $0.requestedYDown,
                       delta: $0.delta,
                       residualTopPt: $0.residualTopPt, residualBottomPt: $0.residualBottomPt)
            }
            self.applied = applied
            self.canRevert = canRevert
        }
    }

    public struct LayoutReport: Codable {
        public var displays: [DisplayReport]
        public var unionMM: RectReport
        public var maxPxPerMM: Double
        public var gaps: [GapReport]
        public var coverage: Double
        /// False while every gap is still zero — seeded from EDID but never measured.
        public var calibrated: Bool
        public var fingerprint: String

        public init(_ layout: PhysicalLayout) {
            displays = layout.entries.map { DisplayReport(display: $0.display, placement: $0.placement) }
            unionMM = RectReport(layout.unionMM)
            maxPxPerMM = Double(layout.maxPxPerMM)
            gaps = layout.horizontalGaps.map {
                GapReport(left: $0.left, right: $0.right,
                          leftUUID: $0.leftUUID, rightUUID: $0.rightUUID,
                          gapMM: Double($0.gapMM))
            }
            coverage = layout.coverage
            calibrated = layout.maxGapMM >= 0.05
            fingerprint = layout.fingerprint
        }
    }

    /// One calibrated display combination, for a front-end that offers a set switcher.
    public struct DisplaySetReport: Codable {
        public var displays: [String]
        public var names: [String]
        public var active: Bool

        public init(_ set: DisplaySet, active: Bool) {
            displays = set.displays
            names = set.displays.compactMap { set.placements[$0]?.name }
            self.active = active
        }
    }

    public struct ConfigReport: Codable {
        public var playlistDirectory: String?
        public var intervalSeconds: Double
        public var shuffle: Bool
        public var recursive: Bool
        /// Decodable images found in the directory now, or nil when it cannot be read —
        /// the two states a front-end must distinguish before blaming an empty folder.
        public var imageCount: Int?
        /// Where these settings live, so a front-end can offer to reveal the file — and so
        /// a test harness can confirm it redirected the support directory before writing.
        public var configPath: String

        public init(_ cfg: CycleConfig, imageCount: Int?) {
            playlistDirectory = cfg.playlistDirectory
            intervalSeconds = cfg.intervalSeconds
            shuffle = cfg.shuffle
            recursive = cfg.recursive
            self.imageCount = imageCount
            configPath = ConfigStore.url.path
        }
    }

    public struct AppliedReport: Codable {
        public struct Screen: Codable {
            public var name: String
            public var pixelWidth: Int
            public var pixelHeight: Int
            public var file: String
            public var cached: Bool
        }

        public var image: String
        /// True when the PNGs were written but the desktop was left alone.
        public var dryRun: Bool
        public var screens: [Screen]

        public init(image: URL, dryRun: Bool, results: [ApplyResult]) {
            self.image = image.path
            self.dryRun = dryRun
            screens = results.map {
                Screen(name: $0.display.name,
                       pixelWidth: $0.display.pixelWidth, pixelHeight: $0.display.pixelHeight,
                       file: $0.url.path, cached: $0.cached)
            }
        }
    }

    public struct RestoredReport: Codable {
        public struct Entry: Codable {
            public var display: String
            public var path: String
        }

        public var restored: [Entry]
        /// Saved displays that are not attached now, so nothing was put back for them.
        public var skipped: Int

        public init(restored: [(display: String, path: String)], skipped: Int) {
            self.restored = restored.map { Entry(display: $0.display, path: $0.path) }
            self.skipped = skipped
        }
    }

    public struct AgentReport: Codable {
        public var label: String
        public var plistPath: String
        public var plistExists: Bool
        public var loaded: Bool
        public var pid: Int?
        public var logPath: String
        /// The binary the plist actually launches. The menu bar app compares this against
        /// the CLI it resolved, to notice an agent left pointing at a moved or stale copy.
        public var program: String?

        public init(label: String) {
            let plist = AgentInstaller.plistURL(label: label)
            self.label = label
            plistPath = plist.path
            plistExists = FileManager.default.fileExists(atPath: plist.path)
            loaded = AgentInstaller.isLoaded(label: label)
            pid = AgentInstaller.pid(label: label)
            logPath = AgentInstaller.logURL.path
            program = AgentInstaller.installedProgram(label: label)?.path
        }
    }
}
