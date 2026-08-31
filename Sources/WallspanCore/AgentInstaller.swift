// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import Foundation

/// Installs `wallspan cycle` as a per-user LaunchAgent. Not cron: `setDesktopImageURL`
/// needs a GUI audit session, which only an agent in the Aqua session gets. `RunAtLoad`
/// also re-applies at login, covering macOS's failure to restore a third-party wallpaper
/// across a restart.
public enum AgentInstaller {
    public static let defaultLabel = "net.serubin.wallspan"

    public static var launchAgentsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    public static func plistURL(label: String) -> URL {
        launchAgentsDir.appendingPathComponent("\(label).plist")
    }

    public static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/wallspan.log")
    }

    public static var defaultBinDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
    }

    public enum AgentError: Error, CustomStringConvertible {
        case cannotLocateBinary
        case launchctl(String, Int32, String)
        case notRunning(String)
        case notExecutable(URL)

        public var description: String {
            switch self {
            case .cannotLocateBinary:
                return "could not determine the path of the running wallspan binary"
            case .launchctl(let cmd, let code, let out):
                return "launchctl \(cmd) failed (exit \(code))\(out.isEmpty ? "" : ":\n  " + out)"
            case .notRunning(let label):
                return "\(label) was bootstrapped but is not running - check \(logURL.path)"
            case .notExecutable(let u):
                return "not an executable file: \(u.path)"
            }
        }
    }

    /// Path of the executable actually running. `Bundle.main.executablePath`, not
    /// `CommandLine.arguments[0]`, which is just "wallspan" when invoked through `PATH`.
    public static func runningBinary() throws -> URL {
        guard let p = Bundle.main.executablePath else { throw AgentError.cannotLocateBinary }
        return URL(fileURLWithPath: p).resolvingSymlinksInPath()
    }

    @discardableResult
    public static func run(_ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static var domain: String { "gui/\(getuid())" }

    public static func makePlist(label: String, binary: URL) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
          "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binary.path)</string>
                <string>cycle</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(logURL.path)</string>
            <key>StandardErrorPath</key>
            <string>\(logURL.path)</string>
            <!-- Redundant (Aqua is the default) but explicit: setDesktopImageURL
                 needs a GUI session. -->
            <key>LimitLoadToSessionType</key>
            <string>Aqua</string>
            <!-- KeepAlive respawns every 10s by default; back off so a persistent
                 failure cannot spin. -->
            <key>ThrottleInterval</key>
            <integer>60</integer>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """
    }

    public struct InstallResult {
        /// The binary the agent will launch — the staged copy, or whatever was named.
        public let binary: URL
        public let plist: URL
        public let pid: Int?
    }

    /// Stages a copy into `binDir`, then points the agent at it. The staging is the point:
    /// it puts `wallspan` on PATH and decouples the agent from the build directory.
    public static func install(label: String, binDir: URL) throws -> InstallResult {
        let source = try runningBinary()
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let staged = binDir.appendingPathComponent("wallspan")

        // Copy unless already running from the staged path: re-install must be idempotent.
        if staged.resolvingSymlinksInPath() != source {
            if FileManager.default.fileExists(atPath: staged.path) {
                try FileManager.default.removeItem(at: staged)
            }
            try FileManager.default.copyItem(at: source, to: staged)
        }
        return try install(label: label, binary: staged)
    }

    /// Points the agent at a binary already in place. Separate from staging: an app bundle
    /// pointing launchd inside itself must not also get a copy that goes stale.
    public static func install(label: String, binary: URL) throws -> InstallResult {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw AgentError.notExecutable(binary)
        }
        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let plist = plistURL(label: label)
        try makePlist(label: label, binary: binary).write(to: plist, atomically: true, encoding: .utf8)

        // Tolerate "not loaded" on the way out, then load fresh.
        _ = try? run(["bootout", "\(domain)/\(label)"])
        let boot = try run(["bootstrap", domain, plist.path])
        guard boot.status == 0 else {
            throw AgentError.launchctl("bootstrap", boot.status, boot.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Give launchd a moment to actually spawn it before reporting a pid.
        Thread.sleep(forTimeInterval: 1.2)
        guard let pid = pid(label: label) else { throw AgentError.notRunning(label) }
        return InstallResult(binary: binary, plist: plist, pid: pid)
    }

    /// What the installed plist launches, or nil. Read from the plist, not `launchctl`, so
    /// it answers for an agent that is installed but not loaded.
    public static func installedProgram(label: String) -> URL? {
        guard let data = try? Data(contentsOf: plistURL(label: label)),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let argv = plist["ProgramArguments"] as? [String],
              let program = argv.first
        else { return nil }
        return URL(fileURLWithPath: program)
    }

    public static func pid(label: String) -> Int? {
        guard let out = try? run(["print", "\(domain)/\(label)"]), out.status == 0 else { return nil }
        for line in out.output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("pid = ") { return Int(t.dropFirst(6).trimmingCharacters(in: .whitespaces)) }
        }
        return nil
    }

    public static func isLoaded(label: String) -> Bool {
        (try? run(["print", "\(domain)/\(label)"]))?.status == 0
    }

    public static func uninstall(label: String, purgeBinary: URL?) throws {
        _ = try? run(["bootout", "\(domain)/\(label)"])
        let plist = plistURL(label: label)
        if FileManager.default.fileExists(atPath: plist.path) {
            try FileManager.default.removeItem(at: plist)
        }
        if let bin = purgeBinary, FileManager.default.fileExists(atPath: bin.path) {
            try FileManager.default.removeItem(at: bin)
        }
    }
}
