// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import Foundation

/// Decides which `wallspan` the app drives: PATH first, the bundled copy as the floor.
///
/// The resolved binary is *executed*, so the choice is never hidden — the menu shows the
/// path, and `preferBundled` stops it looking.
enum BinaryResolver {
    enum Source: String {
        case path = "PATH"
        case wellKnown = "a standard location"
        case bundled = "the app bundle"
    }

    struct Resolution {
        let runner: CLIRunner
        let source: Source
        let version: Contract.Version
        /// Candidates that were found but not used, with why. Shown in About, so "it is
        /// running the wrong one" is diagnosable without a terminal.
        let rejected: [(url: URL, reason: String)]

        var url: URL { runner.binary }
    }

    /// Where a Homebrew or hand-installed CLI lands. Consulted only if the login shell
    /// lookup fails, which it can when an exotic rc file hangs or errors.
    static let wellKnownDirectories = [
        "~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
    ].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

    static var bundledBinary: URL? {
        // Contents/Helpers, not Contents/MacOS: `wallspan` and `Wallspan` cannot share a
        // directory on a case-insensitive volume, which is the macOS default.
        let helpers = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/wallspan")
        if FileManager.default.isExecutableFile(atPath: helpers.path) { return helpers }

        // Running from `swift run` rather than an assembled bundle: the CLI is the sibling
        // product in the same build directory.
        let sibling = Bundle.main.bundleURL.appendingPathComponent("wallspan")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    /// Asks the login shell, because an app launched from Finder inherits launchd's
    /// minimal PATH — Homebrew and `~/.local/bin` are invisible to it. Timed out, since
    /// `-l` sources rc files that can block.
    static func fromLoginShell(timeout: TimeInterval = 3) -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        guard let result = try? CLIRunner.capture(
            URL(fileURLWithPath: shell), ["-lc", "command -v wallspan"], timeout: timeout
        ), result.status == 0 else { return nil }

        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    private enum Probe {
        case usable(Contract.Version)
        case unusable(String)
    }

    /// Accepts a candidate only if it answers `version --json` with a schema this build
    /// understands. A file called `wallspan` that is something else entirely, or a CLI too
    /// old to have the contract, is rejected here rather than at first use.
    private static func probe(_ url: URL) -> Probe {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            return .unusable("not executable")
        }
        let runner = CLIRunner(binary: url)
        guard let version = try? runner.version(timeout: 5) else {
            return .unusable("did not answer `version --json`")
        }
        guard version.schema >= Contract.minimumSchema else {
            return .unusable("schema \(version.schema), need \(Contract.minimumSchema)+")
        }
        return .usable(version)
    }

    static func resolve(preferBundled: Bool = false) -> Resolution? {
        var rejected: [(URL, String)] = []

        var candidates: [(URL, Source)] = []
        if !preferBundled {
            if let shellPath = fromLoginShell() { candidates.append((shellPath, .path)) }
            for dir in wellKnownDirectories {
                let candidate = dir.appendingPathComponent("wallspan")
                // Skip the duplicate rather than probing the same binary twice.
                if !candidates.contains(where: { $0.0.standardizedFileURL == candidate.standardizedFileURL }) {
                    candidates.append((candidate, .wellKnown))
                }
            }
        }
        if let bundled = bundledBinary { candidates.append((bundled, .bundled)) }

        for (url, source) in candidates {
            switch probe(url) {
            case .usable(let version):
                return Resolution(runner: CLIRunner(binary: url), source: source,
                                  version: version, rejected: rejected)
            case .unusable(let reason):
                // A well-known path that simply has nothing in it is not worth reporting.
                if FileManager.default.fileExists(atPath: url.path) {
                    rejected.append((url, reason))
                }
            }
        }
        return nil
    }
}
