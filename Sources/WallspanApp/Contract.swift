// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import Foundation

/// A coding key built from a string at the call site, so a mirror type costs one `init`
/// rather than an `init` plus a `CodingKeys` enum. The strings *are* the wire format, which
/// is what a contract mirror should be spelling out literally anyway.
struct AnyKey: CodingKey {
    let stringValue: String
    init(_ s: String) { stringValue = s }
    init?(stringValue s: String) { stringValue = s }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == AnyKey {
    /// Missing, null or wrong-typed all fall back rather than throw. Swift's synthesized
    /// `init(from:)` ignores property defaults, so one absent field would lose the whole
    /// object — hence the explicit inits below.
    func or<T: Decodable>(_ name: String, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: AnyKey(name))) ?? nil) ?? fallback
    }

    func opt<T: Decodable>(_ name: String) -> T? {
        (try? decodeIfPresent(T.self, forKey: AnyKey(name))) ?? nil
    }
}

/// The app's view of the CLI's `--json` output — see `docs/cli-json-contract.md`.
///
/// Mirrors, not the CLI's own types: the app routinely parses a binary built from different
/// source, so sharing definitions would make every rename a silent breakage.
enum Contract {
    /// The lowest CLI schema this build understands. Compared with `>=`, never `==`:
    /// additive changes do not bump it, and refusing a newer CLI would strand the app on
    /// the bundled copy forever.
    static let minimumSchema = 1

    struct Failure: Decodable, Error, LocalizedError {
        /// A `String`, not an enum: an unrecognised code from a newer CLI must degrade to
        /// "show the message", not to a decode failure that hides it entirely.
        let code: String
        let message: String

        var errorDescription: String? { message }

        init(code: String, message: String) {
            self.code = code
            self.message = message
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            code = c.or("code", "internal_error")
            message = c.or("message", "wallspan reported an error with no message")
        }
    }

    struct Version: Decodable {
        var version: String
        var schema: Int
        var commands: [String]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            version = c.or("version", "unknown")
            // 0 fails the compatibility check, which is the right answer for output that
            // did not carry a schema at all.
            schema = c.or("schema", 0)
            commands = c.or("commands", [])
        }

        func supports(_ command: String) -> Bool { commands.contains(command) }
    }

    struct Status: Decodable {
        var running: Bool
        var pid: Int?
        var paused: Bool
        var intervalSeconds: Double
        var playlistDirectory: String?
        var imageCount: Int?
        var currentImage: String?
        var appliedAt: Date?
        var nextAt: Date?
        var position: String?
        var lastError: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            running = c.or("running", false)
            pid = c.opt("pid")
            paused = c.or("paused", false)
            intervalSeconds = c.or("intervalSeconds", 900)
            playlistDirectory = c.opt("playlistDirectory")
            imageCount = c.opt("imageCount")
            currentImage = c.opt("currentImage")
            appliedAt = c.opt("appliedAt")
            nextAt = c.opt("nextAt")
            position = c.opt("position")
            lastError = c.opt("lastError")
        }
    }

    struct Config: Decodable {
        var playlistDirectory: String?
        var intervalSeconds: Double
        var shuffle: Bool
        var recursive: Bool
        var paused: Bool
        var imageCount: Int?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            playlistDirectory = c.opt("playlistDirectory")
            intervalSeconds = c.or("intervalSeconds", 900)
            shuffle = c.or("shuffle", true)
            recursive = c.or("recursive", false)
            paused = c.or("paused", false)
            imageCount = c.opt("imageCount")
        }
    }

    struct Agent: Decodable {
        var label: String
        var loaded: Bool
        var pid: Int?
        var program: String?
        var programExists: Bool
        var logPath: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            label = c.or("label", "")
            loaded = c.or("loaded", false)
            pid = c.opt("pid")
            program = c.opt("program")
            programExists = c.or("programExists", false)
            logPath = c.opt("logPath")
        }
    }

    struct Display: Decodable {
        var name: String
        var pixelWidth: Int
        var pixelHeight: Int
        var densitySuspect: Bool

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            name = c.or("name", "display")
            pixelWidth = c.or("pixelWidth", 0)
            pixelHeight = c.or("pixelHeight", 0)
            densitySuspect = c.or("densitySuspect", false)
        }
    }

    struct Layout: Decodable {
        var displays: [Display]
        var calibrated: Bool

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            displays = c.or("displays", [])
            calibrated = c.or("calibrated", false)
        }
    }
}

/// `{"schema": N, "<key>": payload}`, or an `error` on failure. The key varies per
/// command, so it arrives via `userInfo` — one envelope, not a struct per command.
struct Envelope<Payload: Decodable>: Decodable {
    let schema: Int
    let payload: Payload?
    let failure: Contract.Failure?

    static var payloadKeyName: CodingUserInfoKey { CodingUserInfoKey(rawValue: "payloadKey")! }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        schema = c.or("schema", 0)
        failure = c.opt("error")
        if let name = decoder.userInfo[Envelope.payloadKeyName] as? String {
            payload = c.opt(name)
        } else {
            payload = nil
        }
    }
}
