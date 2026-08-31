// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import Foundation

/// Cycle settings, kept in a file rather than in the LaunchAgent's arguments: the agent
/// runs plain `wallspan cycle`, so retuning needs no plist rewrite. Re-read every tick.
public struct CycleConfig: Codable, Equatable {
    public var playlistDirectory: String?
    public var intervalSeconds: Double
    public var shuffle: Bool
    public var recursive: Bool
    /// Held here rather than signalled, because `KeepAlive` respawns the agent and a
    /// signal's effect would not survive that — the wallpaper would silently start moving
    /// again after a crash or a logout. Defaulted for configs written before it existed.
    public var paused: Bool

    public init(
        playlistDirectory: String? = nil,
        intervalSeconds: Double = 900,
        shuffle: Bool = true,
        recursive: Bool = false,
        paused: Bool = false
    ) {
        self.playlistDirectory = playlistDirectory
        self.intervalSeconds = intervalSeconds
        self.shuffle = shuffle
        self.recursive = recursive
        self.paused = paused
    }

    /// Explicit so a `config.json` predating `paused` still decodes instead of falling back
    /// to defaults, which would silently discard the user's directory and interval.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playlistDirectory = try c.decodeIfPresent(String.self, forKey: .playlistDirectory)
        intervalSeconds = try c.decodeIfPresent(Double.self, forKey: .intervalSeconds) ?? 900
        shuffle = try c.decodeIfPresent(Bool.self, forKey: .shuffle) ?? true
        recursive = try c.decodeIfPresent(Bool.self, forKey: .recursive) ?? false
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
    }

    public var directoryURL: URL? {
        playlistDirectory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }
}

public enum ConfigStore {
    public static var url: URL {
        StateStore.supportDirectory.appendingPathComponent("config.json")
    }

    static let file = JSONFile<CycleConfig>(url: ConfigStore.url)

    public static func load() -> CycleConfig { file.load(default: CycleConfig()) }
    public static func save(_ cfg: CycleConfig) throws { try file.save(cfg) }

    public static func describe(_ cfg: CycleConfig) -> String {
        var out = "cycle configuration (\(url.path))\n\n"
        out += "  directory : \(cfg.playlistDirectory ?? "(not set)")\n"
        out += "  interval  : \(formatInterval(cfg.intervalSeconds))\n"
        out += "  order     : \(cfg.shuffle ? "shuffled" : "sequential")\n"
        out += "  recursive : \(cfg.recursive)\n"
        if cfg.paused { out += "  paused    : yes  (`wallspan resume` starts it again)\n" }
        if let dir = cfg.directoryURL {
            let n = (try? Playlist.scan(dir, recursive: cfg.recursive).count) ?? 0
            out += "\n  \(n) decodable image(s) found\n"
        }
        return out
    }

    public static func formatInterval(_ s: Double) -> String {
        if s >= 3600, s.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(s / 3600))h" }
        if s >= 60, s.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(s / 60))m" }
        return "\(Int(s))s"
    }
}
