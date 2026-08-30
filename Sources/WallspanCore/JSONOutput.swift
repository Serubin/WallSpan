// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import Foundation

/// The machine-readable half of the CLI, for front-ends that drive it by spawning it.
///
/// Written for a caller older than the binary — a front-end prefers whatever is on PATH —
/// which is what the two rules below follow from.
public enum JSONOutput {
    /// Bumped only for a breaking change — a removed or re-typed field. Adding a field or
    /// a new `code` is not breaking, because every caller is required to ignore what it
    /// does not recognise. Callers accept `schema >= 1`, not `schema == 1`.
    public static let schema = 1

    /// Stable identifiers for failures a front-end must tell apart. `message` is for humans
    /// and may be reworded; the code may not. No better fit means `internalError`.
    public enum ErrorCode: String, Codable {
        case badArgument = "bad_argument"
        case noSuchFile = "no_such_file"
        case noPlaylistDirectory = "no_playlist_directory"
        /// The directory exists but could not be read — usually TCC denying the agent.
        case playlistUnreadable = "playlist_unreadable"
        case playlistEmpty = "playlist_empty"
        case noDisplays = "no_displays"
        case noCalibration = "no_calibration"
        case displayNotFound = "display_not_found"
        case noSavedWallpaper = "no_saved_wallpaper"
        case agentNotRunning = "agent_not_running"
        case alreadyRunning = "already_running"
        case renderFailed = "render_failed"
        case internalError = "internal_error"
    }

    public struct ErrorPayload: Codable {
        public let code: ErrorCode
        public let message: String

        public init(code: ErrorCode, message: String) {
            self.code = code
            self.message = message
        }
    }

    /// ISO-8601 dates, not Swift's reference-date `Double`: the caller is a different
    /// program in a different language on a different release cadence, and 776000000.0 is
    /// only meaningful to Foundation.
    public static func encoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    /// Serialises `{"schema": N, "<key>": payload}`.
    public static func envelope<T: Encodable>(_ payload: T, as key: String) throws -> String {
        let data = try encoder().encode(Envelope(schema: schema, key: key, payload: payload))
        return String(decoding: data, as: UTF8.self)
    }

    public static func errorEnvelope(code: ErrorCode, message: String) -> String {
        // Hand-built rather than encoded: this runs on the failure path, and an envelope
        // that can itself throw leaves the caller with no output at all to parse.
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return """
        {
          "schema" : \(schema),
          "error" : {
            "code" : "\(code.rawValue)",
            "message" : "\(escaped)"
          }
        }
        """
    }
}

/// Writes the payload under a key chosen at runtime, so every command shares one envelope
/// shape without a hand-written `Codable` per command.
private struct Envelope<T: Encodable>: Encodable {
    let schema: Int
    let key: String
    let payload: T

    struct Key: CodingKey {
        let stringValue: String
        init(_ s: String) { stringValue = s }
        init?(stringValue s: String) { stringValue = s }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(schema, forKey: Key("schema"))
        try c.encode(payload, forKey: Key(key))
    }
}
