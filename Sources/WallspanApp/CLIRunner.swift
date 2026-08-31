// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import Foundation

/// Runs `wallspan` and decodes its `--json` output — the app's whole model layer. Anything
/// that cannot be expressed as a subcommand belongs in the CLI, not here.
struct CLIRunner {
    let binary: URL

    enum RunError: Error, LocalizedError {
        case launchFailed(String)
        case timedOut
        case unparseable(String)
        case incompatible(schema: Int)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let why): return "could not run wallspan: \(why)"
            case .timedOut: return "wallspan did not respond"
            case .unparseable(let out):
                return "unexpected output from wallspan: \(out.prefix(200))"
            case .incompatible(let schema):
                return "wallspan speaks schema \(schema); this app needs "
                    + "\(Contract.minimumSchema) or newer"
            }
        }
    }

    /// Blocking, so callers keep it off the main thread. The timeout kills a hung child
    /// rather than letting it wedge the menu.
    @discardableResult
    static func capture(
        _ executable: URL, _ arguments: [String], timeout: TimeInterval = 30
    ) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        // Discarded, not merged into stdout: prose on stderr would corrupt the JSON object
        // the caller is about to parse.
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch {
            throw RunError.launchFailed(error.localizedDescription)
        }

        // Read before waiting. A child that fills the 64 KB pipe buffer blocks writing while
        // the parent blocks waiting, and neither ever moves.
        let data = out.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            throw RunError.timedOut
        }
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// A `Contract.Failure` is thrown as-is, so callers can branch on its stable `code`.
    func json<T: Decodable>(
        _ type: T.Type, key: String, _ arguments: [String], timeout: TimeInterval = 30
    ) throws -> T {
        let result = try CLIRunner.capture(binary, arguments + ["--json"], timeout: timeout)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.userInfo[Envelope<T>.payloadKeyName] = key

        guard let data = result.stdout.data(using: .utf8),
              let envelope = try? decoder.decode(Envelope<T>.self, from: data)
        else { throw RunError.unparseable(result.stdout) }

        if let failure = envelope.failure { throw failure }
        guard envelope.schema >= Contract.minimumSchema else {
            throw RunError.incompatible(schema: envelope.schema)
        }
        guard let payload = envelope.payload else {
            throw RunError.unparseable(result.stdout)
        }
        return payload
    }

    /// For subcommands whose payload the caller does not need. Still parses the envelope,
    /// so a failure surfaces as a `Contract.Failure` rather than a silent no-op.
    func run(_ arguments: [String], timeout: TimeInterval = 30) throws {
        let result = try CLIRunner.capture(binary, arguments + ["--json"], timeout: timeout)
        let decoder = JSONDecoder()
        guard let data = result.stdout.data(using: .utf8),
              let envelope = try? decoder.decode(Envelope<Contract.Status>.self, from: data)
        else {
            // Non-zero with unparseable output is a real failure; zero is a command whose
            // payload simply is not a Status, which is fine because nobody asked for it.
            if result.status != 0 { throw RunError.unparseable(result.stdout) }
            return
        }
        if let failure = envelope.failure { throw failure }
    }

    func version(timeout: TimeInterval = 10) throws -> Contract.Version {
        try json(Contract.Version.self, key: "version", ["version"], timeout: timeout)
    }

    func status() throws -> Contract.Status {
        try json(Contract.Status.self, key: "status", ["status"], timeout: 10)
    }

    func config() throws -> Contract.Config {
        try json(Contract.Config.self, key: "config", ["config", "show"], timeout: 10)
    }

    func agent(label: String? = nil) throws -> Contract.Agent {
        try json(Contract.Agent.self, key: "agent",
                 ["agent", "status"] + (label.map { ["--label", $0] } ?? []), timeout: 10)
    }

    func layout() throws -> Contract.Layout {
        try json(Contract.Layout.self, key: "layout", ["info"], timeout: 10)
    }
}
