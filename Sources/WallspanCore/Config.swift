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

    public init(
        playlistDirectory: String? = nil,
        intervalSeconds: Double = 900,
        shuffle: Bool = true,
        recursive: Bool = false
    ) {
        self.playlistDirectory = playlistDirectory
        self.intervalSeconds = intervalSeconds
        self.shuffle = shuffle
        self.recursive = recursive
    }

    public var directoryURL: URL? {
        playlistDirectory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }
}

public enum ConfigStore {
    public static var url: URL {
        StateStore.supportDirectory.appendingPathComponent("config.json")
    }

    public static func load() -> CycleConfig {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(CycleConfig.self, from: data)
        else { return CycleConfig() }
        return cfg
    }

    public static func save(_ cfg: CycleConfig) throws {
        try StateStore.ensureDirectories()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(cfg).write(to: url, options: .atomic)
    }

    public static func describe(_ cfg: CycleConfig) -> String {
        var out = "cycle configuration (\(url.path))\n\n"
        out += "  directory : \(cfg.playlistDirectory ?? "(not set)")\n"
        out += "  interval  : \(formatInterval(cfg.intervalSeconds))\n"
        out += "  order     : \(cfg.shuffle ? "shuffled" : "sequential")\n"
        out += "  recursive : \(cfg.recursive)\n"
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
