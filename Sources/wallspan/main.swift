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

    /// Flags that take no value; everything else consumes the next token.
    ///
    /// The inverse of an allowlist of value-*taking* flags, which must be extended for
    /// every new option and silently drops the value when it is not. Booleans are stable.
    static let booleanFlags: Set<String> = [
        "dry-run", "sequential", "shuffle", "recursive", "no-recursive",
        "revert", "purge", "help", "h", "json",
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

            let key = a.hasPrefix("--") ? String(a.dropFirst(2)) : String(a.dropFirst(1))
            // --key=value
            if let eq = key.firstIndex(of: "=") {
                let name = String(key[key.startIndex..<eq])
                // Tested here rather than after the booleanFlags check below, which this
                // branch jumps over: `--dry-run=true` would otherwise be filed under
                // `values`, leaving has() false and the apply real.
                if Args.booleanFlags.contains(name) {
                    fail("--\(name) takes no value; it is on when present")
                }
                vals[name] = String(key[key.index(after: eq)...])
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
            i += 1
        }
        positionals = pos; flags = fl; values = vals
    }

    func has(_ f: String) -> Bool { flags.contains(f) }
    func value(_ k: String, _ alt: String? = nil) -> String? {
        values[k] ?? alt.flatMap { values[$0] }
    }
}

/// Read straight from argv rather than from `args`, because `Args.init` itself calls
/// `fail` — a rejected `--dry-run=true` has to come back as JSON too when a front-end
/// asked for JSON.
let jsonMode = CommandLine.arguments.contains("--json")

/// Shadows Swift's `print`: under `--json` one stray line ruins the object being parsed.
/// Guarding each call site was tried first and leaked twice, so the default is safe now.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    guard !jsonMode else { return }
    let text = items.map { "\($0)" }.joined(separator: separator) + terminator
    FileHandle.standardOutput.write(Data(text.utf8))
}

/// The deliberate way past the shadow above, for the one object a caller wants.
func emitRaw(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

func fail(_ message: String, code: JSONOutput.ErrorCode = .badArgument) -> Never {
    if jsonMode {
        // stdout, not stderr: one stream to read, and the exit status still says it failed.
        emitRaw(JSONOutput.errorEnvelope(code: code, message: message))
    } else {
        FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
    }
    exit(1)
}

/// Prints `{"schema": N, "<key>": payload}` and exits. Encoding cannot be allowed to throw
/// past here — a half-written object is worse for the caller than a clean error.
func emit<T: Encodable>(_ payload: T, as key: String) -> Never {
    guard let json = try? JSONOutput.envelope(payload, as: key) else {
        fail("could not encode \(key)", code: .internalError)
    }
    emitRaw(json)
    exit(0)
}

/// Maps the errors a front-end must act on differently onto stable codes. Everything else
/// keeps its description and lands as `internal_error`, which is honest: the caller can
/// show it but cannot branch on it.
func errorCode(for error: Error) -> JSONOutput.ErrorCode {
    switch error {
    case let e as Playlist.PlaylistError:
        if case .empty = e { return .playlistEmpty }
        return .playlistUnreadable
    case let e as PhysicalLayoutError:
        switch e {
        case .noScreens: return .noDisplays
        case .noActiveSet: return .noCalibration
        case .displayNotFound, .ambiguousDisplay: return .displayNotFound
        default: return .internalError
        }
    case is LayoutError:
        return .noDisplays
    case let e as AgentInstaller.AgentError:
        if case .notRunning = e { return .agentNotRunning }
        return .internalError
    case is InstanceLock.LockError:
        return .alreadyRunning
    default:
        return .internalError
    }
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
/// nil when the flag is absent; fails when it is present but unusable.
///
/// `args.value(k).flatMap(parseMM)` collapses "absent" and "present but garbage" into the
/// same nil, so a typo like `--width 800in` was silently skipped and the command still
/// reported success. `positive` additionally rejects 0 and negatives, which parse fine and
/// then trap much later: a zero width makes maxPxPerMM infinite, and converting that to Int
/// is a Swift runtime trap rather than an error message.
///
/// `isFinite` closes that same trap from the other side. `Double` parses "inf" and "nan",
/// and `v <= 0.1` catches neither — NaN compares false against everything — so both reached
/// layout.json and made every later `apply` trap on a value only a hand edit could remove.
///
/// `px` resolves against the density of the panel and axis being adjusted — the unit you
/// can actually count on the test pattern.
func measurement(_ key: String, positive: Bool = false, pxPerMM: CGFloat? = nil) -> CGFloat? {
    // Args files a value-taking flag with nothing usable after it under `flags`, not
    // `values` - so `--width` alone, or `--width --height 300mm`, reads as absent here and
    // the measurement would be skipped with the same false success.
    if args.has(key) { fail("--\(key) needs a value, e.g. --\(key) 20px or --\(key) 797.22mm") }
    guard let raw = args.value(key) else { return nil }
    guard let length = parseLength(raw) else {
        fail("--\(key) needs a length like 20px, 797.22mm, 79.7cm or 797.22 — got '\(raw)'")
    }

    let mm: CGFloat
    switch length {
    case .mm(let v):
        mm = v
    case .px(let v):
        guard let pxPerMM, pxPerMM > 0 else {
            fail("--\(key) cannot be given in px here; use mm")
        }
        mm = v / pxPerMM
    }
    guard mm.isFinite else {
        fail("--\(key) needs a length like 20px, 797.22mm, 79.7cm or 797.22 — got '\(raw)'")
    }
    if positive, mm <= 0.1 {
        fail("--\(key) must be a positive length — got '\(raw)'")
    }
    return mm
}

enum Length {
    case mm(CGFloat)
    /// Pixels of some panel; only meaningful once an axis and a density are known.
    case px(CGFloat)
}

/// "20px", "14mm", "1.4cm", or a bare number of millimetres.
func parseLength(_ s: String) -> Length? {
    let t = s.trimmingCharacters(in: .whitespaces).lowercased()
    if t.hasSuffix("px") { return Double(t.dropLast(2)).map { .px(CGFloat($0)) } }
    if t.hasSuffix("cm") { return Double(t.dropLast(2)).map { .mm(CGFloat($0 * 10)) } }
    if t.hasSuffix("mm") { return Double(t.dropLast(2)).map { .mm(CGFloat($0)) } }
    return Double(t).map { .mm(CGFloat($0)) }
}

func parseMM(_ s: String) -> CGFloat? {
    if case .mm(let v) = parseLength(s) { return v }
    return nil
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
@discardableResult
func applyOnce(
    image: URL, layout: PhysicalLayout, dryRun: Bool, quiet: Bool = false
) throws -> [ApplyResult] {
    // A --json caller is parsing one object off stdout; prose interleaved with it is not
    // parseable, so every commentary path below is off in JSON mode whatever the caller asked.
    let quiet = quiet || jsonMode
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
        return results
    }

    try WallpaperApplier.apply(results)
    if !quiet { print("  applied and verified on \(results.count) display(s)") }
    return results
}

// MARK: - subcommands

let args = Args(CommandLine.arguments)

func cmdInfo() throws {
    let layout = try PhysicalLayoutStore.current()
    if jsonMode { emit(Contract.LayoutReport(layout), as: "layout") }
    print(try Layout.current())
    print()
    print(layout)
}

/// Every subcommand the dispatch switch below accepts, so a front-end can feature-detect
/// rather than parse a version string. Kept beside the switch it describes.
let subcommands = [
    "info", "apply", "preview", "cycle", "verify-mapping", "selftest",
    "layout", "calibrate", "config", "agent", "restore", "status", "next",
    "pause", "resume", "version", "help",
]

func cmdVersion() {
    let report = Contract.VersionReport(
        version: Wallspan.version, schema: JSONOutput.schema, commands: subcommands
    )
    if jsonMode { emit(report, as: "version") }
    print("wallspan \(report.version)  (json schema \(report.schema))")
}

func cmdApply() throws {
    guard let p = args.positionals.first else { fail("usage: wallspan apply <image> [--dry-run]") }
    let image = expand(p)
    guard FileManager.default.fileExists(atPath: image.path) else {
        fail("no such file: \(image.path)", code: .noSuchFile)
    }
    let layout = try PhysicalLayoutStore.current()
    if !jsonMode { print("applying \(image.lastPathComponent)") }

    let dryRun = args.has("dry-run")
    if !dryRun {
        // Snapshot before changing anything, so `restore` has somewhere to go back to.
        var state = StateStore.load()
        snapshotOriginalIfNeeded(&state)
        try StateStore.save(state)
    }
    let results = try applyOnce(image: image, layout: layout, dryRun: dryRun)
    if jsonMode {
        emit(Contract.AppliedReport(image: image, dryRun: dryRun, results: results), as: "applied")
    }
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

// MARK: - physical layout / calibration

func cmdLayout() throws {
    let sub = args.positionals.first ?? "show"
    var layout = try PhysicalLayoutStore.current()

    switch sub {
    case "show":
        if jsonMode { emit(Contract.LayoutReport(layout), as: "layout") }
        print(layout)
        print("set: \(layout.entries.map(\.placement.name).joined(separator: " + "))")
        print("config: \(PhysicalLayoutStore.configURL.path)")

    case "list":
        let cfg = PhysicalLayoutStore.load()
        let active = (try? PhysicalLayoutStore.activeKey()) ?? []
        // Emitted before the empty check below: "nothing calibrated yet" is a normal state
        // for a caller building a set switcher, so it gets an empty array. The prose path
        // keeps its error, which is the right affordance for someone who just typed it.
        if jsonMode {
            emit(cfg.sets.map { Contract.DisplaySetReport($0, active: $0.displays == active) },
                 as: "sets")
        }
        guard !cfg.sets.isEmpty else { fail("no display sets calibrated yet", code: .noCalibration) }
        for s in cfg.sets.sorted(by: { $0.displays.count < $1.displays.count }) {
            let names = s.displays.compactMap { s.placements[$0]?.name }.joined(separator: " + ")
            print("\(s.displays == active ? " *" : "  ") \(s.displays.count)  \(names)")
        }
        print("\n* = attached now. Each set keeps its own calibration.")

    case "reset":
        // Scoped to the active set; other display combinations keep their calibration.
        var (cfg, i) = try PhysicalLayoutStore.loadActive()
        cfg.sets[i].placements = try PhysicalLayoutStore.seed(from: try Layout.current())
        try PhysicalLayoutStore.save(cfg)
        if jsonMode { emit(Contract.LayoutReport(try PhysicalLayoutStore.current()), as: "layout") }
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
        var (cfg, active) = try PhysicalLayoutStore.loadActive()
        guard var p = cfg.sets[active].placements[uuid] else { fail("display not in config") }
        guard let entry = layout.entries.first(where: { $0.placement.uuid == uuid })
        else { fail("display not attached") }

        // Per axis: a hand-set size can still be anisotropic even though a seeded one is not.
        let pxPerMMX = CGFloat(entry.display.pixelWidth) / p.sizeMM.width
        let pxPerMMY = CGFloat(entry.display.pixelHeight) / p.sizeMM.height

        switch sub {
        case "nudge":
            let dx = measurement("dx", pxPerMM: pxPerMMX) ?? 0
            let dy = measurement("dy", pxPerMM: pxPerMMY) ?? 0
            guard dx != 0 || dy != 0 else { fail("nudge needs --dx and/or --dy, e.g. --dx 20px") }
            p.originMM = CGPoint(x: p.originMM.x + dx, y: p.originMM.y + dy)
            cfg.sets[active].placements[uuid] = p
            print(String(format: "%@: origin %+.0f, %+.0f px -> (%.1f, %.1f) mm",
                         p.name, dx * pxPerMMX, dy * pxPerMMY, p.originMM.x, p.originMM.y))
        case "set":
            // Not `positive`: a negative origin is legitimate — the portrait panel sits
            // at negative y in the calibrated layout.
            if let x = measurement("origin-x", pxPerMM: pxPerMMX) { p.originMM.x = x }
            if let y = measurement("origin-y", pxPerMM: pxPerMMY) { p.originMM.y = y }
            cfg.sets[active].placements[uuid] = p
            print(String(format: "%@: origin = (%.1f, %.1f) mm", p.name, p.originMM.x, p.originMM.y))
        default:
            var size = p.sizeMM

            // Same control as --width/--height, but tunable by eye: a scale error shows as
            // circles breaking across the seam.
            if let percent = args.value("scale").flatMap(Double.init) {
                guard percent > 1, percent < 1000 else { fail("--scale is a percent, e.g. 100.6") }
                size.width *= CGFloat(percent / 100)
                size.height *= CGFloat(percent / 100)
            } else if let ppi = args.value("ppi").flatMap(Double.init) {
                guard ppi > 1 else { fail("--ppi must be positive, e.g. 109.6") }
                size.width = CGFloat(Double(entry.display.pixelWidth) / (ppi / 25.4))
                size.height = CGFloat(Double(entry.display.pixelHeight) / (ppi / 25.4))
            } else {
                if let w = measurement("width", positive: true) { size.width = w }
                if let h = measurement("height", positive: true) { size.height = h }
            }

            let (dw, dh) = PhysicalLayoutStore.resize(uuid, to: size,
                                                      in: &cfg.sets[active].placements)
            p = cfg.sets[active].placements[uuid] ?? p
            print(String(format: "%@: active area = %.1f x %.1f mm  (%.2f PPI)",
                         p.name, size.width, size.height,
                         Double(entry.display.pixelWidth) / Double(size.width / 25.4)))
            if dw != 0 {
                print(String(format: "  shifted displays to the right by %+.1f mm to preserve gaps", dw))
            }
            if dh != 0 {
                print(String(format: "  held vertical centre (bottom edge moved %+.1f mm)", -dh / 2))
            }
        }

        try PhysicalLayoutStore.save(cfg)
        layout = try PhysicalLayoutStore.current()
        if jsonMode { emit(Contract.LayoutReport(layout), as: "layout") }
        for g in layout.horizontalGaps {
            print(String(format: "  gap %@ | %@ = %.1f mm", g.left, g.right, g.gapMM))
        }
        print("\nrun `wallspan calibrate` to see the effect")

    default:
        fail("unknown: wallspan layout \(sub)"
             + "  (show | list | reset | nudge | set | size | arrange)")
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
        if jsonMode {
            // Re-planned after the revert, so the targets describe where things now stand
            // rather than the deltas that were just undone.
            emit(Contract.ArrangeReport(targets: DisplayArranger.plan(layout),
                                        applied: true, canRevert: true), as: "arrange")
        }
        for o in origins { print("restored \(o.name): y = \(o.y)") }
        return
    }

    let targets = DisplayArranger.plan(layout)
    let canRevert = StateStore.load().originalArrangement?.isEmpty == false
    // A single display is a normal state to report, not a failure: a front-end asking what
    // arranging would do should get "nothing", not an error it has to special-case.
    if jsonMode, targets.isEmpty {
        emit(Contract.ArrangeReport(targets: [], applied: false, canRevert: canRevert),
             as: "arrange")
    }
    guard !targets.isEmpty else {
        fail("only one display attached; nothing to arrange")
    }

    if jsonMode, args.has("dry-run") {
        emit(Contract.ArrangeReport(targets: targets, applied: false, canRevert: canRevert),
             as: "arrange")
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
        if jsonMode {
            emit(Contract.ArrangeReport(targets: targets, applied: false, canRevert: canRevert),
                 as: "arrange")
        }
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
    if jsonMode {
        emit(Contract.ArrangeReport(targets: DisplayArranger.plan(layout),
                                    applied: true, canRevert: true), as: "arrange")
    }
    print("applied permanently and verified by read-back")
}

func cmdCalibrate() throws {
    let layout = try PhysicalLayoutStore.current()
    guard let pattern = CalibrationPattern.make(
        unionMM: layout.unionMM, anchorMM: layout.anchorMM, pxPerMM: layout.maxPxPerMM
    ) else { fail("could not build calibration pattern") }

    let dir = StateStore.renderDirectory.appendingPathComponent("calibration", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let src = dir.appendingPathComponent("pattern-\(layout.fingerprint.prefix(12)).png")
    try WallpaperApplier.writePNG(pattern, to: src)

    // Both suppressed under --json by the shadowed `print`.
    print("calibration pattern (\(pattern.width)x\(pattern.height))")
    print("  anchored on \(layout.anchorDisplay.display.name)")
    // --dry-run leaves the desktop alone, so the pattern and crops can be inspected
    // without first losing whatever is on screen.
    let dryRun = args.has("dry-run")
    if dryRun {
        if !jsonMode { print("  source -> \(src.path)") }
    } else {
        var state = StateStore.load()
        snapshotOriginalIfNeeded(&state)
        try StateStore.save(state)
    }
    try applyOnce(image: src, layout: layout, dryRun: dryRun)
    // The layout, not an acknowledgement: a caller adjusting in a loop wants the gaps the
    // pattern it is looking at was drawn for.
    if jsonMode { emit(Contract.LayoutReport(layout), as: "layout") }
    for g in layout.horizontalGaps {
        print(String(format: "  current gap %@ | %@ = %.1f mm", g.left, g.right, g.gapMM))
    }
    print("""

    Look across the bezel:
      - yellow/green DIAGONALS should stay collinear. A break means the gap is wrong.
        Lines stepping DOWN-right => gap too small. Stepping UP-right => too large.
      - red HORIZONTAL rules isolate vertical error; they should not step.
      - the 10mm grid is a scale reference you can check with a tape measure.
      - the bullseye marks the centre of the main display and holds still while you
        nudge the others. It moves only if you change which display macOS calls main.

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
          + (layout.maxGapMM >= 0.05
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
        fail("no saved wallpaper to restore (wallspan has not applied anything yet)",
             code: .noSavedWallpaper)
    }
    let restored = try WallpaperApplier.restore(snaps)
    guard !restored.isEmpty else {
        fail("none of the \(snaps.count) saved display(s) are attached; nothing restored",
             code: .noSavedWallpaper)
    }
    if jsonMode {
        emit(Contract.RestoredReport(restored: restored, skipped: snaps.count - restored.count),
             as: "restored")
    }
    for r in restored { print("restored \(r.display): \(r.path)") }
    if restored.count < snaps.count {
        print("\(snaps.count - restored.count) saved display(s) not attached; skipped")
    }
}

// MARK: - cycle

/// Command-line values that outrank the config file. Re-applied after every reload, not
/// merged once at startup - `cycle` re-reads the file each tick.
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
    /// True while an apply is in flight. Needed because the read-back now turns the run
    /// loop instead of blocking it, so a timer or a queued block can land mid-apply. Every
    /// path that applies goes through `apply(_:layout:)` to hold it, or two applies
    /// interleave on the same screens.
    var applying = false
    /// Separate from `debounce`, or a display change would cancel a pending Space follow.
    var spaceDebounce: DispatchWorkItem?
    /// Spaces get switched dozens of times an hour; log the follow once per image.
    var spaceFollowLogged = false

    init(layout: PhysicalLayout, config: CycleConfig, overrides: CycleOverrides) {
        self.layout = layout
        self.config = config
        self.overrides = overrides
    }

    var interval: TimeInterval { config.intervalSeconds }

    /// Polls the config file's mtime so `config set` lands independently of the interval —
    /// otherwise lowering an hourly interval means waiting an hour. mtime, not a
    /// `DispatchSource` watch: `ConfigStore.save` replaces the inode, deafening a watch.
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
        let wasPaused = config.paused
        config = fresh

        if fresh.paused != wasPaused {
            print("[\(timestamp())] config changed: \(fresh.paused ? "paused" : "resumed")")
            // Resuming waits for the next tick otherwise, which on an hourly interval means
            // an hour of looking broken. Restart the clock from now and change immediately.
            if !fresh.paused {
                scheduleTimer()
                // Cancelled by any advance that gets there first: pressing Resume and then
                // Next inside the config-watch window would otherwise queue this behind a
                // manual advance and consume two playlist entries for one intended change.
                resumeTick?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.tick() }
                resumeTick = work
                DispatchQueue.main.async(execute: work)
            }
        }
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

    /// Re-ticks after a backoff; without it an unusable directory stalls the run.
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
            var status = StatusStore.load()
            status.lastError = "\(error)"
            StatusStore.save(status)
            scheduleRetry()
            return nil
        }
    }

    /// The cycler's only route to `applyOnce`, so `applying` cannot be bypassed.
    /// Saves and restores rather than clearing, so a caller already holding the flag
    /// (`advance`) still holds it when this returns.
    /// Returns the failure, if any, so the caller can put it in `status.json` — a front-end
    /// has no other way to see it, and the agent cannot raise a prompt.
    @discardableResult
    func apply(_ image: URL, layout: PhysicalLayout) -> String? {
        let wasApplying = applying
        applying = true
        defer { applying = wasApplying }
        do {
            try applyOnce(image: image, layout: layout, dryRun: false, quiet: true)
            return nil
        } catch {
            FileHandle.standardError.write("  failed: \(error)\n".data(using: .utf8)!)
            return "\(error)"
        }
    }

    /// Re-runs a tick that landed mid-apply. Single-flight, like `retryWork`.
    var deferredTick: DispatchWorkItem?

    /// The immediate change a resume triggers. Single-flight and cancelled by any advance,
    /// so it cannot stack with a manual `next`.
    var resumeTick: DispatchWorkItem?

    func tick() {
        // Guarded here rather than in advance(): draining the run loop lets the tick Timer
        // fire mid-apply, and ensurePlaylist() would then swap `playlist` out from under
        // the apply still running - persisting a fresh playlist's index for the image the
        // old one produced.
        //
        // Deferred, not dropped. `ensurePlaylist` is the only caller of `scheduleRetry`, so
        // returning outright would end the backoff chain that keeps retrying an unavailable
        // playlist directory - one retry landing inside a read-back and the folder is never
        // looked at again. On the main path it would silently eat a tick whenever an apply
        // overruns the interval, which is what the short interval in the test recipe does.
        guard !applying else {
            print("[\(timestamp())] tick deferred: previous apply still running")
            deferredTick?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.tick() }
            deferredTick = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
            return
        }
        reloadConfigIfChanged()
        // After the reload, so a resume written to the config takes effect on this tick
        // rather than the one after it.
        guard !config.paused else { return }
        guard ensurePlaylist() != nil else { return }
        advance()
    }

    /// What `wallspan next` triggers: change now, and stay paused if we were.
    ///
    /// Pause governs the *schedule*, not manual control — a front-end offering both a pause
    /// switch and a Next button would otherwise have a Next that silently does nothing
    /// whenever the switch is on, which reads as a broken button rather than a policy.
    func advanceNow() {
        guard !applying else {
            print("[\(timestamp())] next ignored: an apply is already running")
            return
        }
        reloadConfigIfChanged()
        guard ensurePlaylist() != nil else { return }
        // Restarting the interval is only meaningful when one is running.
        if !config.paused { scheduleTimer() }
        advance()
    }

    func advance() {
        guard playlist != nil else { return }
        // Whatever route got here satisfies a pending resume-triggered tick.
        resumeTick?.cancel()
        resumeTick = nil
        // Held across the whole of advance(), not just the apply: the playlist entry is
        // consumed here, and consuming it must be inside the same guarded window that the
        // apply is, or a re-entrant tick could take a second entry.
        applying = true
        defer { applying = false }
        // Mutated in place, not through a local copy written back on exit: `playlist` can
        // be set to nil while this is running (reloadConfigIfChanged does exactly that when
        // the directory changes), and a deferred write-back would resurrect the stale copy
        // still pointing at the old folder.
        let image = playlist!.next()
        // After next(), index is the 1-based position of the item just returned; reading
        // it before misreports the wraparound tick.
        let position = "\(playlist!.index)/\(playlist!.order.count)"
        current = image
        spaceFollowLogged = false
        print("[\(timestamp())] \(position)  \(image.lastPathComponent)")

        // Snapshot BEFORE applying, and persist before the desktop changes:
        // `currentWallpapers()` reads the live desktop and `originalWallpaper` is
        // write-once, so capturing it later records our own render, permanently.
        var state = StateStore.load()
        if state.originalWallpaper == nil {
            snapshotOriginalIfNeeded(&state)
            try? StateStore.save(state)
        }

        let failure = apply(image, layout: layout)
        var status = StatusStore.load()
        status.position = position
        status.intervalSeconds = interval
        if let failure {
            // The desktop still shows whatever last succeeded, so currentImage and
            // appliedAt keep pointing at that rather than at the image that failed.
            status.lastError = failure
        } else {
            status.currentImage = image.path
            status.appliedAt = Date()
            status.lastError = nil
        }
        StatusStore.save(status)

        // Reload rather than reusing the copy from before the apply: the run loop turned
        // in between, so that copy may be stale.
        var after = StateStore.load()
        // Optional-chained rather than forced: the playlist can be cleared mid-apply, and
        // persisting the old position would write an index for a directory we have left.
        playlist?.persist(into: &after)
        try? StateStore.save(after)
    }

    /// Display arrangement changed: re-render the *current* image for the new layout
    /// rather than advancing the playlist.
    func layoutChanged() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // The main-queue drain inside an apply's read-back runs this block, so it can
            // land mid-apply. Re-arm rather than proceed: re-rendering now would set new
            // URLs on screens the running apply is still polling the read-back for, and it
            // would fail on the ones we replaced. Re-arm rather than skip, too - the
            // arrangement really did change, and dropping it leaves the desktop rendered
            // for the old one until the next tick.
            guard !self.applying else { self.layoutChanged(); return }
            guard let newLayout = try? PhysicalLayoutStore.current() else { return }
            guard newLayout.fingerprint != self.layout.fingerprint else { return }
            self.layout = newLayout
            print("[\(timestamp())] display arrangement changed -> "
                  + "union \(Int(newLayout.unionMM.width))x\(Int(newLayout.unionMM.height))mm, re-rendering")
            if let img = self.current { self.apply(img, layout: newLayout) }
        }
        debounce = work
        // Reconfiguration fires repeatedly per change; settle before reacting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// Re-applies the current image on arrival at a Space: `setDesktopImageURL` only ever
    /// reached whichever Space was in front at the last tick. Unconditional, because
    /// `desktopImageURL(for:)` reports one path for every Space and cannot show staleness.
    func spaceChanged() {
        spaceDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Re-arm, not skip: the Space we arrived on still needs the image.
            guard !self.applying else { self.spaceChanged(); return }
            guard let img = self.current else { return }
            if !self.spaceFollowLogged {
                self.spaceFollowLogged = true
                print("[\(timestamp())] space changed -> \(img.lastPathComponent)"
                      + " (further switches on this image are silent)")
            }
            self.apply(img, layout: self.layout)
        }
        spaceDebounce = work
        // Outlasts the switch animation, and collapses a swipe across several Spaces.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

var cycler: Cycler?
/// Global so the lock outlives cmdCycle's frame. RunLoop.main.run() never returns, but a
/// local would still leave ownership ambiguous.
var cycleLock: InstanceLock?

func reconfigCallback(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ ctx: UnsafeMutableRawPointer?) {
    // Ignore the "about to change" half of each notification pair.
    guard !flags.contains(.beginConfigurationFlag) else { return }
    cycler?.layoutChanged()
}

/// Subscribes `cycle` to Space switches; the caller must then run `NSApplication`, since
/// the notification was measured to arrive only under AppKit's loop, never under
/// `RunLoop.main.run()`. False without a GUI session, where `NSApplication` would abort.
func startFollowingSpaces() -> Bool {
    guard CGSessionCopyCurrentDictionary() != nil else { return false }
    let app = NSApplication.shared
    // The policy the notification was measured under; the default `.prohibited` refuses.
    app.setActivationPolicy(.accessory)
    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
    ) { _ in cycler?.spaceChanged() }
    return true
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

    // Held for the life of the process; released by the kernel if we die abnormally.
    do {
        cycleLock = try InstanceLock.acquire()
    } catch {
        fail("\(error)")
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
    let followsSpaces = startFollowingSpaces()
    print(followsSpaces
          ? "following Space changes: each Space gets the current wallpaper on arrival"
          : "not a GUI session: Space changes will not be followed")
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

    // `wallspan next` advances the running cycler. A signal, because "change now" has
    // nothing durable worth persisting — unlike pause, which is config precisely so it
    // survives a respawn.
    let sigusr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    sigusr1.setEventHandler {
        print("[\(c.timestamp())] next requested")
        c.advanceNow()
    }
    sigusr1.resume()
    // Mandatory: SIGUSR1 terminates by default and the dispatch source does not change
    // that, so without this `next` kills the agent.
    signal(SIGUSR1, SIG_IGN)

    // Both service the same RunLoop.main sources — including the signal above; only
    // AppKit's delivers the Space-change notification.
    if followsSpaces { NSApplication.shared.run() } else { RunLoop.main.run() }
}

// MARK: - config + agent

/// Applies the cycle flags to `cfg`, reporting whether anything changed. Shared by
/// `config set` and `agent install` so they cannot disagree about flags or validation.
func applyConfigFlags(to cfg: inout CycleConfig) -> Bool {
    var touched = false
    if let d = args.value("dir") {
        let url = expand(d)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue
        else { fail("not a directory: \(url.path)", code: .noSuchFile) }
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
    return touched
}

/// `imageCount` is nil when the directory could not be scanned at all, and 0 when it was
/// read and held nothing. A front-end needs the difference: the first is a permissions or
/// unmounted-volume problem, the second is an empty folder.
func configReport(_ cfg: CycleConfig) -> Contract.ConfigReport {
    let count = cfg.directoryURL.flatMap { try? Playlist.scan($0, recursive: cfg.recursive).count }
    return Contract.ConfigReport(cfg, imageCount: count)
}

// MARK: - status + running-cycler control

/// "in 8m" / "7m ago" / "just now". Coarse on purpose: a status line refreshed on a timer
/// that claims "in 7m 43s" is wrong a second later.
func relative(_ date: Date, from now: Date = Date()) -> String {
    let d = date.timeIntervalSince(now)
    let mag = abs(d)
    guard mag >= 45 else { return "just now" }
    let text = mag < 3600
        ? "\(Int((mag / 60).rounded()))m"
        : String(format: "%.1fh", mag / 3600)
    return d < 0 ? "\(text) ago" : "in \(text)"
}

func cmdStatus() throws {
    let cfg = ConfigStore.load()
    let report = Contract.StatusReport(
        config: cfg, status: StatusStore.load(),
        imageCount: cfg.directoryURL.flatMap { try? Playlist.scan($0, recursive: cfg.recursive).count },
        holder: InstanceLock.holder()
    )
    if jsonMode { emit(report, as: "status") }

    let pid = report.pid.map { " (pid \($0))" } ?? ""
    print("cycling   : \(report.running ? "yes\(pid)" : "no")")
    print("paused    : \(report.paused ? "yes" : "no")")
    print("interval  : \(ConfigStore.formatInterval(report.intervalSeconds))")
    if let dir = report.playlistDirectory {
        // nil count means the scan failed, which is a different problem from an empty
        // folder — and saying "unreadable" for a directory nobody set would be nonsense.
        print("directory : \(dir)  (\(report.imageCount.map { "\($0) images" } ?? "unreadable"))")
    } else {
        print("directory : (not set)")
    }
    if let image = report.currentImage {
        let pos = report.position.map { "  \($0)" } ?? ""
        print("current   : \(URL(fileURLWithPath: image).lastPathComponent)\(pos)")
    }
    if let at = report.appliedAt { print("applied   : \(relative(at))") }
    if let next = report.nextAt { print("next      : \(relative(next))") }
    if let err = report.lastError { print("last error: \(err)") }
    if !report.running {
        print("\nnothing is cycling. `wallspan agent install` runs it in the background,")
        print("or `wallspan cycle <dir>` in the foreground.")
    }
}

/// Writes `paused` and lets the running agent notice, rather than signalling it: the agent
/// re-reads the config within five seconds, and unlike a signal the setting survives the
/// `KeepAlive` respawn that a crash or a logout would cause.
func cmdPause(_ paused: Bool) throws {
    var cfg = ConfigStore.load()
    cfg.paused = paused
    try ConfigStore.save(cfg)
    if jsonMode { emit(configReport(cfg), as: "config") }

    print(paused ? "paused" : "resumed")
    if InstanceLock.holder() != nil {
        print(paused
              ? "the running cycler stops at its next check (within 5s)"
              : "the running cycler changes the wallpaper within 5s")
    } else {
        print("nothing is cycling right now; this takes effect when it starts")
    }
}

func cmdNext() throws {
    guard let pid = InstanceLock.holder() else {
        fail("""
        nothing is cycling, so there is nothing to advance.
               `wallspan agent install` runs it in the background.
        """, code: .agentNotRunning)
    }
    // A held lock with an unreadable pid: the cycler is alive but cannot be addressed.
    guard pid > 0 else {
        fail("a cycler holds \(InstanceLock.defaultPath.path) but did not record its pid",
             code: .internalError)
    }
    guard kill(pid, SIGUSR1) == 0 else {
        fail("could not signal pid \(pid): \(String(cString: strerror(errno)))",
             code: .internalError)
    }
    if jsonMode { emit(Contract.SignalReport(pid: pid, signal: "SIGUSR1"), as: "next") }
    print("asked pid \(pid) to change now")
}

func cmdConfig() throws {
    let sub = args.positionals.first ?? "show"
    switch sub {
    case "show":
        let cfg = ConfigStore.load()
        if jsonMode { emit(configReport(cfg), as: "config") }
        print(ConfigStore.describe(cfg))

    case "set":
        var cfg = ConfigStore.load()
        guard applyConfigFlags(to: &cfg) else {
            fail("nothing to set. options: --dir <path> --interval 15m --shuffle|--sequential --recursive|--no-recursive")
        }
        try ConfigStore.save(cfg)
        if jsonMode { emit(configReport(cfg), as: "config") }
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
        if applyConfigFlags(to: &cfg) { try ConfigStore.save(cfg) }

        guard let dir = cfg.directoryURL else {
            fail("""
            no playlist directory configured. Either:
                   wallspan agent install --dir ~/Pictures/Backgrounds --interval 15m
                 or set it first with `wallspan config set --dir <path>`
            """)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue
        else { fail("configured directory does not exist: \(dir.path)", code: .noSuchFile) }

        // --binary points the agent at a binary that already lives where it should, with
        // no staged copy. An app bundle uses this to run the CLI from inside itself; a copy
        // in ~/.local/bin would go stale the moment the app updated.
        let r = try args.value("binary").map { try AgentInstaller.install(label: label, binary: expand($0)) }
            ?? AgentInstaller.install(label: label, binDir: binDir)
        if jsonMode { emit(Contract.AgentReport(label: label), as: "agent") }
        print("installed \(label)")
        print("  binary  -> \(r.binary.path)")
        print("  plist   -> \(r.plist.path)")
        print("  log     -> \(AgentInstaller.logURL.path)")
        print("  running -> pid \(r.pid.map(String.init) ?? "?")")
        print()
        print(ConfigStore.describe(cfg))
        print("retune any time with `wallspan config set --interval 30m` - the agent picks")
        print("it up on the next tick. `wallspan agent uninstall` removes it.")

    case "status":
        if jsonMode { emit(Contract.AgentReport(label: label), as: "agent") }
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
        if jsonMode { emit(Contract.AgentReport(label: label), as: "agent") }
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

    DRIVING A RUNNING CYCLER
      wallspan status
          What is on screen, whether anything is cycling, and when the next
          change is due.

      wallspan next
          Change now. Works while paused, and leaves it paused - pausing stops
          the schedule, not the button.

      wallspan pause
      wallspan resume
          A setting rather than a signal, so it survives a reboot and the agent
          restarting. A running agent notices within a few seconds.

    RUNNING IT UNATTENDED
      wallspan config set --dir ~/Pictures/Backgrounds --interval 15m
      wallspan config show
          The directory and interval live in a file, so retuning does not mean
          touching the LaunchAgent. A running agent picks changes up next tick.

      wallspan agent install [--dir <path>] [--interval 15m]
                            [--binary <path>] [--label <label>]
      wallspan agent status
      wallspan agent uninstall [--purge]
          Installs `wallspan cycle` as a per-user LaunchAgent, which also
          re-applies at login. It has to be a LaunchAgent and not a cron job:
          setDesktopImageURL needs a GUI session, which cron does not have.

          By default it stages a copy into ~/.local/bin, which also puts
          wallspan on your PATH. --binary points launchd at a binary that
          already lives where it should and stages nothing - for a copy inside
          an app bundle, where a second copy would go stale on the next update.

    BEZEL CALIBRATION
      Monitors have bezels; macOS places displays edge-to-edge and cannot express
      the gap. wallspan models each panel's active area in millimetres instead, so
      content that falls behind a bezel is rendered and discarded - which is what
      makes the picture look continuous.

      wallspan layout show
      wallspan layout list                                # every calibrated set
      wallspan layout nudge <display> --dx 20px --dy -4px
      wallspan layout size  <display> --ppi 109.6         # or --scale 100.6
      wallspan layout size  <display> --width 797.2mm     # if you have the spec sheet
      wallspan layout reset                               # back to edge-to-edge

      Lengths take px, mm or cm. Panel sizes are corrected to square pixels on the
      way in - `layout show` says when it has. A size wrong in both axes at once
      survives that, and shows as circles breaking across the seam; `--ppi` and
      `--scale` dial it out by eye.

      Calibration is per display SET: the laptop alone, the two externals, and
      all three together each keep their own. Editing one leaves the rest
      untouched, and a new combination inherits from the closest one you have
      already measured.

      wallspan layout arrange [--dry-run] [--revert]
          Push the calibrated VERTICAL offsets into macOS's own display
          arrangement, with exact integer precision rather than by dragging in
          System Settings. Horizontal is untouched - macOS forces displays to be
          contiguous and cannot represent a bezel gap at all.

      wallspan calibrate [--dry-run]
          Apply a diagonal test pattern, pinned to the centre of the main
          display so it holds still while you move the others. --dry-run
          renders it without changing your desktop. Diagonals are the
          sensitive instrument: the eye spots a break in a straight line
          far below one pixel.

    CORRECTNESS
      wallspan verify-mapping <image|directory>
          Inverts the render: checks each output pixel came from the source pixel
          the layout says it should. Valid at any bezel gap.

      wallspan selftest
          Offset sweep proving the geometry. Edge-to-edge layouts only.

      wallspan restore
          Put back whatever wallpaper you had before wallspan first ran.
    """)
}

/// Subcommands with a defined `--json` payload. Everything else rejects the flag rather
/// than emitting prose a caller cannot tell from a crash.
let jsonCapable: Set<String> = [
    "info", "apply", "restore", "layout", "config", "agent",
    "status", "next", "pause", "resume", "version", "calibrate",
]

if jsonMode, !jsonCapable.contains(args.subcommand) {
    fail("--json is not supported for `\(args.subcommand)`"
         + "  (supported: \(jsonCapable.sorted().joined(separator: ", ")))")
}

do {
    switch args.subcommand {
    case "info":        try cmdInfo()
    case "apply":       try cmdApply()
    case "preview":     try cmdPreview()
    case "cycle":       try cmdCycle()
    case "verify-mapping": try cmdVerifyMapping()
    case "selftest":    try cmdSelfTest()
    case "layout":      try cmdLayout()
    case "calibrate":   try cmdCalibrate()
    case "config":      try cmdConfig()
    case "agent":       try cmdAgent()
    case "restore":     try cmdRestore()
    case "status":      try cmdStatus()
    case "next":        try cmdNext()
    case "pause":       try cmdPause(true)
    case "resume":      try cmdPause(false)
    case "version", "--version": cmdVersion()
    case "help", "--help", "-h": usage()
    default:
        // usage() to stdout would corrupt the object a --json caller is parsing.
        if !jsonMode { usage() }
        fail("unknown subcommand: \(args.subcommand)")
    }
} catch {
    fail("\(error)", code: errorCode(for: error))
}
