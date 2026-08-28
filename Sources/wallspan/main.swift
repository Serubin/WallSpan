// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit
import WallspanCore

// stdout is block-buffered when not a TTY, so piping long-running `cycle` would show
// nothing for hours.
setvbuf(stdout, nil, _IONBF, 0)

// MARK: - tiny arg parser

struct Args {
    let subcommand: String
    let positionals: [String]
    private let flags: Set<String>
    private let values: [String: String]

    /// Flags that take no value. Everything else consumes the next token.
    ///
    /// The inverse of an allowlist of value-*taking* flags, which has to be extended for
    /// every new option and silently drops the value when it is not. Booleans are the
    /// small, stable set.
    static let booleanFlags: Set<String> = [
        "dry-run", "sequential", "shuffle", "recursive", "no-recursive",
        "revert", "purge", "help", "h",
    ]

    init(_ argv: [String]) {
        var rest = Array(argv.dropFirst())
        subcommand = rest.isEmpty ? "help" : rest.removeFirst()
        var pos: [String] = [], fl: Set<String> = [], vals: [String: String] = [:]
        var i = 0
        while i < rest.count {
            let a = rest[i]
            let isFlag = a.hasPrefix("--") || (a.hasPrefix("-") && a.count == 2)
            guard isFlag else { pos.append(a); i += 1; continue }

            var key = a.hasPrefix("--") ? String(a.dropFirst(2)) : String(a.dropFirst(1))
            // --key=value
            if let eq = key.firstIndex(of: "=") {
                vals[String(key[key.startIndex..<eq])] = String(key[key.index(after: eq)...])
                i += 1
                continue
            }
            if Args.booleanFlags.contains(key) {
                fl.insert(key); i += 1; continue
            }
            if i + 1 < rest.count, !rest[i + 1].hasPrefix("--") {
                vals[key] = rest[i + 1]; i += 2; continue
            }
            // Unknown flag with nothing after it: record it so `has()` still sees it.
            fl.insert(key)
            key = ""
            i += 1
        }
        positionals = pos; flags = fl; values = vals
    }

    func has(_ f: String) -> Bool { flags.contains(f) }
    func value(_ k: String, _ alt: String? = nil) -> String? {
        values[k] ?? alt.flatMap { values[$0] }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
    exit(1)
}

/// "15m", "90s", "2h", or a bare number of seconds.
func parseInterval(_ s: String) -> TimeInterval? {
    let t = s.trimmingCharacters(in: .whitespaces).lowercased()
    guard let last = t.last else { return nil }
    let multipliers: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
    if let m = multipliers[last] {
        guard let n = Double(t.dropLast()), n > 0 else { return nil }
        return n * m
    }
    guard let n = Double(t), n > 0 else { return nil }
    return n
}

func expand(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

/// "14mm", "14", "-3.5mm", "1.4cm" -> millimetres.
func parseMM(_ s: String) -> CGFloat? {
    let t = s.trimmingCharacters(in: .whitespaces).lowercased()
    if t.hasSuffix("cm") { return Double(t.dropLast(2)).map { CGFloat($0 * 10) } }
    if t.hasSuffix("mm") { return Double(t.dropLast(2)).map { CGFloat($0) } }
    return Double(t).map { CGFloat($0) }
}

// MARK: - shared pipeline

/// Decode target for a physical layout: the union's physical extent at the highest panel
/// density, so the densest display is fully served.
func decodeTarget(_ layout: PhysicalLayout) -> CGSize {
    CGSize(width: layout.unionMM.width * layout.maxPxPerMM,
           height: layout.unionMM.height * layout.maxPxPerMM)
}

/// Load -> render. Shared by apply / preview / verify so geometry cannot disagree.
func renderSpan(image: URL, layout: PhysicalLayout) throws -> (SourceImage, [RenderedScreen]) {
    let source = try ImageLoader.load(image, covering: decodeTarget(layout))
    return (source, SpanRenderer.render(source: source.image, layout: layout))
}

func describe(_ source: SourceImage) -> String {
    let n = source.nativeSize, d = source.decodedSize
    let mp = (n.width * n.height) / 1_000_000
    if source.wasDownsampled {
        return String(format: "source %.0fx%.0f (%.0f MP) -> decoded %.0fx%.0f",
                      n.width, n.height, mp, d.width, d.height)
    }
    return String(format: "source %.0fx%.0f (%.0f MP), decoded at native", n.width, n.height, mp)
}

/// Captured once so `restore` always returns to the pre-wallspan desktop.
func snapshotOriginalIfNeeded(_ state: inout WallspanState) {
    guard state.originalWallpaper == nil else { return }
    state.originalWallpaper = WallpaperApplier.currentWallpapers()
}

/// Renders and applies one image. Deliberately does NOT touch persisted state: the caller
/// owns it, so there is exactly one load/save per operation.
func applyOnce(image: URL, layout: PhysicalLayout, dryRun: Bool, quiet: Bool = false) throws {
    var loaded: SourceImage?
    let results = try WallpaperApplier.materialize(source: image, layout: layout) {
        let (source, rendered) = try renderSpan(image: image, layout: layout)
        guard !rendered.isEmpty else { throw ApplyError.pngEncodeFailed(image) }
        loaded = source
        return rendered
    }
    if !quiet {
        if let loaded { print("  \(describe(loaded))") }
        for r in results {
            print("  \(r.display.name): \(r.display.pixelWidth)x\(r.display.pixelHeight)"
                  + " -> \(r.url.lastPathComponent)\(r.cached ? " (cached)" : "")")
        }
    }

    if dryRun {
        if !quiet {
            print("  --dry-run: desktop untouched. Files in "
                  + results[0].url.deletingLastPathComponent().path)
        }
        return
    }

    try WallpaperApplier.apply(results)
    if !quiet { print("  applied and verified on \(results.count) display(s)") }
}

// MARK: - subcommands

let args = Args(CommandLine.arguments)

func cmdInfo() throws {
    print(try Layout.current())
    print()
    print(try PhysicalLayoutStore.current())
}

func cmdApply() throws {
    guard let p = args.positionals.first else { fail("usage: wallspan apply <image> [--dry-run]") }
    let image = expand(p)
    guard FileManager.default.fileExists(atPath: image.path) else { fail("no such file: \(image.path)") }
    let layout = try PhysicalLayoutStore.current()
    print("applying \(image.lastPathComponent)")

    let dryRun = args.has("dry-run")
    if !dryRun {
        // Snapshot before changing anything, so `restore` has somewhere to go back to.
        var state = StateStore.load()
        snapshotOriginalIfNeeded(&state)
        state.lastApplied = image.path
        try StateStore.save(state)
    }
    try applyOnce(image: image, layout: layout, dryRun: dryRun)
}

func cmdPreview() throws {
    guard let p = args.positionals.first else { fail("usage: wallspan preview <image> -o <out.png>") }
    let image = expand(p)
    let out = expand(args.value("out", "o") ?? "wallspan-preview.png")
    let layout = try PhysicalLayoutStore.current()
    let source = try ImageLoader.load(image, covering: decodeTarget(layout))
    guard let preview = SpanRenderer.renderPreview(source: source.image, layout: layout) else {
        fail("preview render failed")
    }
    try WallpaperApplier.writePNG(preview, to: out)
    print("\(describe(source))")
    print("wrote \(out.path) (\(preview.width)x\(preview.height))")
    print("bright regions are what your panels show; dimmed regions are bezel gaps and dead space")
}

func cmdVerifySeam() throws {
    let layout = try PhysicalLayoutStore.current()
    guard SeamVerifier.maxGapMM(layout) < 0.05 else {
        fail("""
        verify-seam assumes panels are edge-to-edge, but a bezel gap of \
        \(String(format: "%.1f", SeamVerifier.maxGapMM(layout)))mm is configured.
               A calibrated seam is discontinuous by design, so this check no longer means
               anything. Use `wallspan verify-mapping` instead.
        """)
    }
    let targets: [URL]
    if args.positionals.isEmpty {
        fail("usage: wallspan verify-seam <image|directory>")
    }
    let first = expand(args.positionals[0])
    var isDir: ObjCBool = false
    FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir)
    targets = isDir.boolValue
        ? try Playlist.scan(first, recursive: args.has("recursive"))
        : args.positionals.map(expand)

    var failures = 0
    for image in targets {
        let (source, rendered) = try renderSpan(image: image, layout: layout)
        let reports = SeamVerifier.verify(rendered: rendered, layout: layout)
        if reports.isEmpty {
            print("\(image.lastPathComponent): no horizontally adjacent display pair to check")
            continue
        }
        for r in reports {
            let mark = r.passed ? "PASS" : "FAIL"
            if !r.passed { failures += 1 }
            let name = image.lastPathComponent.padding(toLength: 42, withPad: " ", startingAt: 0)
            print(String(format: "%@ %@  join %7.3f  interior %7.3f  ratio %6.3f",
                         name, mark, r.joinGradient, r.interiorGradient, r.ratio))
        }
        _ = source
    }
    if failures > 0 { fail("\(failures) seam check(s) failed") }
    print("\nall seam checks passed")
}

// MARK: - physical layout / calibration

func cmdLayout() throws {
    let sub = args.positionals.first ?? "show"
    var layout = try PhysicalLayoutStore.current()

    switch sub {
    case "show":
        print(layout)
        print("config: \(PhysicalLayoutStore.configURL.path)")

    case "reset":
        let cfg = try PhysicalLayoutStore.seed(from: try Layout.current())
        try PhysicalLayoutStore.save(cfg)
        print("re-seeded from EDID + current arrangement (gaps back to 0)")
        if StateStore.load().originalArrangement != nil {
            print("note: seeding derives origins from the macOS arrangement, which you have")
            print("      since changed with `layout arrange` - so this is not a return to")
            print("      the original seed.")
        }
        print()
        print(try PhysicalLayoutStore.current())

    case "arrange":
        try cmdArrange(layout)

    case "nudge", "set", "size":
        guard args.positionals.count >= 2 else {
            fail("usage: wallspan layout \(sub) <display> ...  (display = index or name substring)")
        }
        let uuid = try PhysicalLayoutStore.resolve(args.positionals[1], in: layout)
        var cfg = PhysicalLayoutStore.load()
        guard var p = cfg.placements[uuid] else { fail("display not in config") }

        switch sub {
        case "nudge":
            let dx = args.value("dx").flatMap(parseMM) ?? 0
            let dy = args.value("dy").flatMap(parseMM) ?? 0
            guard dx != 0 || dy != 0 else { fail("nudge needs --dx and/or --dy, e.g. --dx 14mm") }
            p.originMM = CGPoint(x: p.originMM.x + dx, y: p.originMM.y + dy)
            print(String(format: "%@: origin %+.1f, %+.1f mm -> (%.1f, %.1f)",
                         p.name, dx, dy, p.originMM.x, p.originMM.y))
        case "set":
            if let x = args.value("origin-x").flatMap(parseMM) { p.originMM.x = x }
            if let y = args.value("origin-y").flatMap(parseMM) { p.originMM.y = y }
            print(String(format: "%@: origin = (%.1f, %.1f) mm", p.name, p.originMM.x, p.originMM.y))
        default:
            // Correcting a measurement must not move the panel or invent a gap.
            // Horizontally, everything to the right shifts by the width delta, preserving
            // calibrated gaps. Vertically the centre is held: a re-measured panel did not
            // physically move, so anchoring its bottom edge would translate it.
            let oldW = p.sizeMM.width, oldH = p.sizeMM.height
            if let w = args.value("width").flatMap(parseMM) { p.sizeMM.width = w }
            if let h = args.value("height").flatMap(parseMM) { p.sizeMM.height = h }
            p.originMM.y -= (p.sizeMM.height - oldH) / 2
            let dw = p.sizeMM.width - oldW
            cfg.placements[uuid] = p
            if dw != 0 {
                for (k, var other) in cfg.placements where k != uuid {
                    if other.originMM.x > p.originMM.x {
                        other.originMM.x += dw
                        cfg.placements[k] = other
                    }
                }
            }
            print(String(format: "%@: active area = %.1f x %.1f mm", p.name, p.sizeMM.width, p.sizeMM.height))
            if dw != 0 {
                print(String(format: "  shifted displays to the right by %+.1f mm to preserve gaps", dw))
            }
            if p.sizeMM.height != oldH {
                print(String(format: "  held vertical centre (bottom edge moved %+.1f mm)",
                             -(p.sizeMM.height - oldH) / 2))
            }
        }

        cfg.placements[uuid] = p
        try PhysicalLayoutStore.save(cfg)
        layout = try PhysicalLayoutStore.current()
        for g in layout.horizontalGaps {
            print(String(format: "  gap %@ | %@ = %.1f mm", g.left, g.right, g.gapMM))
        }
        print("\nrun `wallspan calibrate` to see the effect")

    default:
        fail("unknown: wallspan layout \(sub)  (show | reset | nudge | set | size | arrange)")
    }
}

/// Pushes the calibrated vertical offsets into macOS's display arrangement.
func cmdArrange(_ layout: PhysicalLayout) throws {
    if args.has("revert") {
        guard let snaps = StateStore.load().originalArrangement, !snaps.isEmpty else {
            fail("no saved arrangement (wallspan has not run `layout arrange` yet)")
        }
        var origins: [(id: CGDirectDisplayID, name: String, x: Int, y: Int)] = []
        for e in layout.entries {
            guard let s = snaps.first(where: { $0.uuid == e.placement.uuid }) else { continue }
            origins.append((e.display.id, e.placement.name, s.x, s.y))
        }
        guard !origins.isEmpty else { fail("saved arrangement does not match attached displays") }
        try DisplayArranger.apply(origins)
        for o in origins { print("restored \(o.name): y = \(o.y)") }
        return
    }

    let targets = DisplayArranger.plan(layout)
    guard !targets.isEmpty else {
        fail("only one display attached; nothing to arrange")
    }

    print("macOS arrangement (y-down points; main display stays put, horizontal untouched)\n")
    var anyChange = false
    for t in targets {
        print("  \(t.display.name)")
        print("    current   y = \(t.currentYDown)")
        print("    requested y = \(t.requestedYDown)   (\(t.delta >= 0 ? "+" : "")\(t.delta) pt)")
        if abs(t.residualTopPt) > 0.5 || abs(t.residualBottomPt) > 0.5 {
            print(String(format: "    residual    %+.1f pt at the top of the overlap, %+.1f pt at the bottom",
                         t.residualTopPt, t.residualBottomPt))
            print("                (panel densities differ; this cannot be removed, only centred)")
        }
        if t.delta != 0 { anyChange = true }
    }

    guard anyChange else {
        print("\nalready matches the calibrated layout; nothing to do")
        return
    }
    if args.has("dry-run") {
        print("\n--dry-run: arrangement untouched")
        return
    }

    var state = StateStore.load()
    if state.originalArrangement == nil {
        state.originalArrangement = DisplayArranger.currentArrangement(layout)
        try StateStore.save(state)
        print("\nsaved current arrangement (`wallspan layout arrange --revert` restores it)")
    }

    let origins = targets.map {
        (id: $0.display.id, name: $0.display.name,
         x: Int(CGDisplayBounds($0.display.id).origin.x.rounded()), y: $0.requestedYDown)
    }
    try DisplayArranger.apply(origins)
    print("applied permanently and verified by read-back")
}

func cmdCalibrate() throws {
    let layout = try PhysicalLayoutStore.current()
    guard let pattern = CalibrationPattern.make(
        unionMM: layout.unionMM, pxPerMM: layout.maxPxPerMM
    ) else { fail("could not build calibration pattern") }

    let dir = StateStore.renderDirectory.appendingPathComponent("calibration", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let src = dir.appendingPathComponent("pattern-\(layout.fingerprint.prefix(12)).png")
    try WallpaperApplier.writePNG(pattern, to: src)

    var state = StateStore.load()
    snapshotOriginalIfNeeded(&state)
    try StateStore.save(state)

    print("calibration pattern (\(pattern.width)x\(pattern.height))")
    try applyOnce(image: src, layout: layout, dryRun: false)
    for g in layout.horizontalGaps {
        print(String(format: "  current gap %@ | %@ = %.1f mm", g.left, g.right, g.gapMM))
    }
    print("""

    Look across the bezel:
      - yellow/green DIAGONALS should stay collinear. A break means the gap is wrong.
        Lines stepping DOWN-right => gap too small. Stepping UP-right => too large.
      - red HORIZONTAL rules isolate vertical error; they should not step.
      - the 10mm grid is an absolute reference you can check with a tape measure.

    Adjust, then re-run:
      wallspan layout nudge <display> --dx 14mm --dy -3mm
      wallspan calibrate
      wallspan restore          # when you are done
    """)
}

func cmdVerifyMapping() throws {
    let layout = try PhysicalLayoutStore.current()
    guard !args.positionals.isEmpty else {
        fail("usage: wallspan verify-mapping <image|directory>")
    }
    let first = expand(args.positionals[0])
    var isDir: ObjCBool = false
    FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir)
    let targets = isDir.boolValue
        ? try Playlist.scan(first, recursive: args.has("recursive"))
        : args.positionals.map(expand)

    var failures = 0
    for image in targets {
        let (source, rendered) = try renderSpan(image: image, layout: layout)
        let reports = MappingVerifier.verify(
            source: source.image, rendered: rendered, layout: layout
        )
        print(image.lastPathComponent)
        for r in reports {
            print("  \(r)")
            if !r.passed { failures += 1 }
        }
    }
    if failures > 0 { fail("\(failures) mapping check(s) failed") }
    print("\nall mapping checks passed"
          + (SeamVerifier.maxGapMM(layout) >= 0.05
             ? " (with a calibrated bezel gap - this check stays valid there)" : ""))
}

func cmdSelfTest() throws {
    let layout = try PhysicalLayoutStore.current()
    guard layout.entries.count >= 2 else {
        print("selftest needs at least two displays; only \(layout.entries.count) attached.")
        print("`wallspan verify-mapping <image>` is the meaningful check on a single display.")
        return
    }
    guard let report = MappingVerifier.selfTest(layout: layout) else {
        fail("self-test could not render the test pattern")
    }
    print(report)
    if !report.passed { exit(1) }
}

func cmdRestore() throws {
    let state = StateStore.load()
    guard let snaps = state.originalWallpaper, !snaps.isEmpty else {
        fail("no saved wallpaper to restore (wallspan has not applied anything yet)")
    }
    let restored = try WallpaperApplier.restore(snaps)
    guard !restored.isEmpty else {
        fail("none of the \(snaps.count) saved display(s) are attached; nothing restored")
    }
    for r in restored { print("restored \(r.display): \(r.path)") }
    if restored.count < snaps.count {
        print("\(snaps.count - restored.count) saved display(s) not attached; skipped")
    }
}

// MARK: - cycle

/// Command-line values that outrank the config file.
///
/// Re-applied on top of every reload rather than merged once at startup: `cycle` re-reads
/// the file each tick, so a one-shot merge is overwritten by the first reload.
struct CycleOverrides {
    var playlistDirectory: String?
    var recursive: Bool?
    var shuffle: Bool?
    var intervalSeconds: TimeInterval?

    func applied(to cfg: CycleConfig) -> CycleConfig {
        var out = cfg
        if let d = playlistDirectory { out.playlistDirectory = d }
        if let r = recursive { out.recursive = r }
        if let s = shuffle { out.shuffle = s }
        if let i = intervalSeconds { out.intervalSeconds = i }
        return out
    }
}

/// Held globally because CGDisplayRegisterReconfigurationCallback takes a C function
/// pointer, which cannot capture context.
final class Cycler {
    var playlist: Playlist?
    var current: URL?
    var layout: PhysicalLayout
    var config: CycleConfig
    let overrides: CycleOverrides
    var timer: Timer?
    var configWatch: Timer?
    var configMTime: Date?
    var debounce: DispatchWorkItem?
    /// Backoff while the playlist directory is unavailable: a folder on an external or
    /// network volume is genuinely absent at login, and under KeepAlive exiting respawns.
    var retryDelay: TimeInterval = 15
    /// Single-flight, so retries cannot compound: both the repeating timer and each retry
    /// call `tick()`.
    var retryWork: DispatchWorkItem?

    init(layout: PhysicalLayout, config: CycleConfig, overrides: CycleOverrides) {
        self.layout = layout
        self.config = config
        self.overrides = overrides
    }

    var interval: TimeInterval { config.intervalSeconds }

    /// Polls the config file's mtime so `config set` is picked up independently of the
    /// interval — re-reading only per tick would mean waiting an hour to lower an hourly
    /// interval. mtime, not a `DispatchSource` watch: `ConfigStore.save` writes
    /// atomically, replacing the inode, so a watch would go deaf after the first edit.
    func startConfigWatch() {
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let m = (try? FileManager.default.attributesOfItem(atPath: ConfigStore.url.path)[.modificationDate]) as? Date
            guard m != self.configMTime else { return }
            self.configMTime = m
            self.reloadConfigIfChanged()
        }
        RunLoop.main.add(t, forMode: .common)
        configWatch = t
    }

    func reloadConfigIfChanged() {
        // Overrides are re-applied here, so a command-line argument survives every reload.
        let fresh = overrides.applied(to: ConfigStore.load())
        guard fresh != config else { return }
        let oldInterval = interval, oldDir = config.playlistDirectory, oldShuffle = config.shuffle
        config = fresh

        if fresh.playlistDirectory != oldDir || fresh.shuffle != oldShuffle
            || fresh.recursive != playlist?.recursiveScan {
            print("[\(timestamp())] config changed: playlist -> "
                  + (fresh.playlistDirectory ?? "(unset)"))
            playlist = nil          // rebuilt on the next tick
        }
        if interval != oldInterval {
            print("[\(timestamp())] config changed: interval -> \(ConfigStore.formatInterval(interval))")
            scheduleTimer()
        }
    }

    func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Re-ticks after a backoff. Every unusable-directory path needs this, or the run
    /// stalls until the next scheduled tick.
    func scheduleRetry() {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.tick() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
        retryDelay = min(retryDelay * 2, max(interval, 60))
    }

    /// Builds the playlist, or returns nil if the directory is not currently usable.
    func ensurePlaylist() -> Playlist? {
        if let p = playlist { return p }
        guard let dir = config.directoryURL else {
            print("[\(timestamp())] no playlist directory configured - run "
                  + "`wallspan config set --dir <path>`; retrying in \(Int(retryDelay))s")
            scheduleRetry()
            return nil
        }
        do {
            let p = try Playlist(
                directory: dir, recursive: config.recursive,
                shuffled: config.shuffle, resuming: StateStore.load()
            )
            playlist = p
            retryDelay = 15
            retryWork?.cancel()
            retryWork = nil
            return p
        } catch {
            print("[\(timestamp())] playlist unavailable (\(error)); retrying in \(Int(retryDelay))s")
            scheduleRetry()
            return nil
        }
    }

    func tick() {
        reloadConfigIfChanged()
        guard ensurePlaylist() != nil else { return }
        advance()
    }

    func advance() {
        guard var pl = playlist else { return }
        let image = pl.next()
        defer { playlist = pl }
        // After next(), index is the 1-based position of the item just returned; reading
        // it before misreports the wraparound tick.
        let position = "\(pl.index)/\(pl.order.count)"
        current = image
        print("[\(timestamp())] \(position)  \(image.lastPathComponent)")

        // Snapshot BEFORE applying, and persist it before the desktop changes.
        // `currentWallpapers()` reads the live desktop and `originalWallpaper` is
        // write-once, so capturing it afterwards would record our own render and lose the
        // real wallpaper permanently.
        var state = StateStore.load()
        if state.originalWallpaper == nil {
            snapshotOriginalIfNeeded(&state)
            try? StateStore.save(state)
        }

        do {
            try applyOnce(image: image, layout: layout, dryRun: false, quiet: true)
        } catch {
            FileHandle.standardError.write("  failed: \(error)\n".data(using: .utf8)!)
        }
        // Persist even if applying failed, so a transient failure cannot replay the image.
        state.lastApplied = image.path
        pl.persist(into: &state)
        try? StateStore.save(state)
    }

    /// Display arrangement changed: re-render the *current* image for the new layout
    /// rather than advancing the playlist.
    func layoutChanged() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let newLayout = try? PhysicalLayoutStore.current() else { return }
            guard newLayout.fingerprint != self.layout.fingerprint else { return }
            self.layout = newLayout
            print("[\(timestamp())] display arrangement changed -> "
                  + "union \(Int(newLayout.unionMM.width))x\(Int(newLayout.unionMM.height))mm, re-rendering")
            if let img = self.current {
                try? applyOnce(image: img, layout: newLayout, dryRun: false, quiet: true)
            }
        }
        debounce = work
        // Reconfiguration fires repeatedly per change; settle before reacting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

var cycler: Cycler?

func reconfigCallback(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ ctx: UnsafeMutableRawPointer?) {
    // Ignore the "about to change" half of each notification pair.
    guard !flags.contains(.beginConfigurationFlag) else { return }
    cycler?.layoutChanged()
}

func cmdCycle() throws {
    // Settings come from the config file so the LaunchAgent's ProgramArguments is just
    // `wallspan cycle`. Explicit flags outrank the file for the whole run, not just the
    // first tick - see CycleOverrides.
    var overrides = CycleOverrides()
    if let p = args.positionals.first { overrides.playlistDirectory = expand(p).path }
    if args.has("recursive") { overrides.recursive = true }
    if args.has("no-recursive") { overrides.recursive = false }
    if args.has("sequential") { overrides.shuffle = false }
    if args.has("shuffle") { overrides.shuffle = true }
    if let s = args.value("interval") {
        guard let i = parseInterval(s) else { fail("bad --interval: \(s)") }
        overrides.intervalSeconds = i
    }

    let config = overrides.applied(to: ConfigStore.load())
    guard config.playlistDirectory != nil else {
        fail("""
        no playlist directory. Either pass one:
               wallspan cycle <directory>
             or set it once and let the config drive it:
               wallspan config set --dir ~/Pictures/Backgrounds --interval 15m
        """)
    }

    let layout = try PhysicalLayoutStore.current()
    let c = Cycler(layout: layout, config: config, overrides: overrides)
    cycler = c

    print("cycling \(config.playlistDirectory!)")
    print("interval \(ConfigStore.formatInterval(c.interval)), "
          + "\(config.shuffle ? "shuffled" : "sequential")"
          + (overrides.intervalSeconds == nil
             ? "  (from \(ConfigStore.url.lastPathComponent); re-read each tick)"
             : "  (--interval overrides config)"))
    print("ctrl-c to stop; run `wallspan restore` to put your old wallpaper back\n")

    c.tick()
    c.scheduleTimer()
    c.startConfigWatch()
    CGDisplayRegisterReconfigurationCallback(reconfigCallback, nil)

    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler {
        print("\nstopped. `wallspan restore` returns your previous wallpaper.")
        exit(0)
    }
    sigint.resume()
    signal(SIGINT, SIG_IGN)

    RunLoop.main.run()
}

// MARK: - config + agent

func cmdConfig() throws {
    let sub = args.positionals.first ?? "show"
    switch sub {
    case "show":
        print(ConfigStore.describe(ConfigStore.load()))

    case "set":
        var cfg = ConfigStore.load()
        var touched = false
        if let d = args.value("dir") {
            let url = expand(d)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue
            else { fail("not a directory: \(url.path)") }
            cfg.playlistDirectory = url.path; touched = true
        }
        if let s = args.value("interval") {
            guard let i = parseInterval(s) else { fail("bad --interval: \(s)") }
            cfg.intervalSeconds = i; touched = true
        }
        if args.has("sequential") { cfg.shuffle = false; touched = true }
        if args.has("shuffle") { cfg.shuffle = true; touched = true }
        if args.has("recursive") { cfg.recursive = true; touched = true }
        if args.has("no-recursive") { cfg.recursive = false; touched = true }
        guard touched else {
            fail("nothing to set. options: --dir <path> --interval 15m --shuffle|--sequential --recursive|--no-recursive")
        }
        try ConfigStore.save(cfg)
        print(ConfigStore.describe(cfg))
        if AgentInstaller.isLoaded(label: args.value("label") ?? AgentInstaller.defaultLabel) {
            print("the running agent re-reads this on its next tick; no restart needed")
        }

    default:
        fail("unknown: wallspan config \(sub)  (show | set)")
    }
}

func cmdAgent() throws {
    let sub = args.positionals.first ?? "status"
    let label = args.value("label") ?? AgentInstaller.defaultLabel
    let binDir = args.value("bin-dir").map(expand) ?? AgentInstaller.defaultBinDir

    switch sub {
    case "install":
        // Let install double as `config set`, so one command gets you running.
        var cfg = ConfigStore.load()
        var touched = false
        if let d = args.value("dir") { cfg.playlistDirectory = expand(d).path; touched = true }
        if let s = args.value("interval") {
            guard let i = parseInterval(s) else { fail("bad --interval: \(s)") }
            cfg.intervalSeconds = i; touched = true
        }
        if args.has("sequential") { cfg.shuffle = false; touched = true }
        if args.has("recursive") { cfg.recursive = true; touched = true }
        if touched { try ConfigStore.save(cfg) }

        guard let dir = cfg.directoryURL else {
            fail("""
            no playlist directory configured. Either:
                   wallspan agent install --dir ~/Pictures/Backgrounds --interval 15m
                 or set it first with `wallspan config set --dir <path>`
            """)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue
        else { fail("configured directory does not exist: \(dir.path)") }

        let r = try AgentInstaller.install(label: label, binDir: binDir)
        print("installed \(label)")
        print("  binary  -> \(r.stagedBinary.path)")
        print("  plist   -> \(r.plist.path)")
        print("  log     -> \(AgentInstaller.logURL.path)")
        print("  running -> pid \(r.pid.map(String.init) ?? "?")")
        print()
        print(ConfigStore.describe(cfg))
        print("retune any time with `wallspan config set --interval 30m` - the agent picks")
        print("it up on the next tick. `wallspan agent uninstall` removes it.")

    case "status":
        let plist = AgentInstaller.plistURL(label: label)
        let loaded = AgentInstaller.isLoaded(label: label)
        print("label   : \(label)")
        print("plist   : \(plist.path)\(FileManager.default.fileExists(atPath: plist.path) ? "" : "  (missing)")")
        print("loaded  : \(loaded ? "yes" : "no")")
        if let p = AgentInstaller.pid(label: label) { print("pid     : \(p)") }
        print("log     : \(AgentInstaller.logURL.path)")
        print()
        print(ConfigStore.describe(ConfigStore.load()))
        if let log = try? String(contentsOf: AgentInstaller.logURL, encoding: .utf8) {
            let tail = log.split(separator: "\n").suffix(6)
            if !tail.isEmpty {
                print("recent log:")
                for l in tail { print("  \(l)") }
            }
        }

    case "uninstall":
        let bin = args.has("purge") ? binDir.appendingPathComponent("wallspan") : nil
        try AgentInstaller.uninstall(label: label, purgeBinary: bin)
        print("removed \(label)")
        if bin != nil { print("purged staged binary") }
        print("your wallpaper is unchanged; `wallspan restore` reverts it")

    default:
        fail("unknown: wallspan agent \(sub)  (install | status | uninstall)")
    }
}

func usage() {
    print("""
    wallspan - span one wallpaper across multiple displays, and cycle a folder

    USAGE
      wallspan info
          Show the display arrangement, the union rect, and how much of a source
          image lands in dead space.

      wallspan preview <image> -o <out.png>
          Render the whole union with each display outlined and dead space dimmed.
          Does not touch your desktop.

      wallspan apply <image> [--dry-run]
          Render per-display crops and set them as wallpaper. --dry-run writes the
          PNGs and prints their paths without changing anything.

      wallspan cycle [directory] [--interval 15m] [--shuffle|--sequential]
                     [--recursive|--no-recursive]
          Walk a folder on an interval. Re-renders automatically if you rearrange
          or unplug a display. Runs in the foreground. With no arguments it reads
          the config, and re-reads it every tick.

    RUNNING IT UNATTENDED
      wallspan config set --dir ~/Pictures/Backgrounds --interval 15m
      wallspan config show
          The directory and interval live in a file, so retuning does not mean
          touching the LaunchAgent. A running agent picks changes up next tick.

      wallspan agent install [--dir <path>] [--interval 15m]
      wallspan agent status
      wallspan agent uninstall [--purge]
          Installs `wallspan cycle` as a per-user LaunchAgent, which also
          re-applies at login. It has to be a LaunchAgent and not a cron job:
          setDesktopImageURL needs a GUI session, which cron does not have.

    BEZEL CALIBRATION
      Monitors have bezels; macOS places displays edge-to-edge and cannot express
      the gap. wallspan models each panel's active area in millimetres instead, so
      content that falls behind a bezel is rendered and discarded - which is what
      makes the picture look continuous.

      wallspan layout show
      wallspan layout nudge <display> --dx 14mm --dy -3mm
      wallspan layout size  <display> --width 797.2mm     # override bad EDID
      wallspan layout reset                               # back to edge-to-edge

      wallspan layout arrange [--dry-run] [--revert]
          Push the calibrated VERTICAL offsets into macOS's own display
          arrangement, with exact integer precision rather than by dragging in
          System Settings. Horizontal is untouched - macOS forces displays to be
          contiguous and cannot represent a bezel gap at all.

      wallspan calibrate
          Apply a diagonal test pattern. Diagonals are the sensitive instrument:
          the eye spots a break in a straight line far below one pixel.

    CORRECTNESS
      wallspan verify-mapping <image|directory>
          Inverts the render: checks each output pixel came from the source pixel
          the layout says it should. Valid at any bezel gap.

      wallspan selftest
          Offset sweep proving the geometry. Edge-to-edge layouts only.

      wallspan verify-seam <image|directory> [--recursive]
          Per-image continuity sanity check. Edge-to-edge layouts only, and weak
          on near-flat images by nature.

      wallspan restore
          Put back whatever wallpaper you had before wallspan first ran.
    """)
}

do {
    switch args.subcommand {
    case "info":        try cmdInfo()
    case "apply":       try cmdApply()
    case "preview":     try cmdPreview()
    case "cycle":       try cmdCycle()
    case "verify-seam": try cmdVerifySeam()
    case "verify-mapping": try cmdVerifyMapping()
    case "selftest":    try cmdSelfTest()
    case "layout":      try cmdLayout()
    case "calibrate":   try cmdCalibrate()
    case "config":      try cmdConfig()
    case "agent":       try cmdAgent()
    case "restore":     try cmdRestore()
    case "help", "--help", "-h": usage()
    default:
        usage()
        fail("unknown subcommand: \(args.subcommand)")
    }
} catch {
    fail("\(error)")
}
