// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import Foundation

/// What the cycler last did, written every tick.
///
/// Its own file, not `state.json`: that holds the write-once `originalWallpaper` snapshot
/// `restore` needs, and a status feed would rewrite it ~96 times a day.
public struct CycleStatus: Codable {
    public var currentImage: String?
    public var appliedAt: Date?
    /// "12/40" — position within the current pass, for a front-end that shows progress.
    public var position: String?
    /// Why the last tick failed, cleared by the next one that succeeds. This is how an
    /// unreadable playlist directory reaches the UI: the agent cannot show a TCC prompt,
    /// so without this the folder simply appears to do nothing.
    public var lastError: String?
    /// The interval the cycler is *actually* using, which is not always the one in
    /// `config.json`: `cycle --interval 10m` overrides the file for the life of that run.
    /// Without this, a countdown computed from the config is simply wrong for the whole run.
    public var intervalSeconds: Double?
    public var updatedAt: Date

    public init(
        currentImage: String? = nil,
        appliedAt: Date? = nil,
        position: String? = nil,
        lastError: String? = nil,
        intervalSeconds: Double? = nil,
        updatedAt: Date = Date()
    ) {
        self.currentImage = currentImage
        self.appliedAt = appliedAt
        self.position = position
        self.lastError = lastError
        self.intervalSeconds = intervalSeconds
        self.updatedAt = updatedAt
    }
}

public enum StatusStore {
    public static var url: URL {
        StateStore.supportDirectory.appendingPathComponent("status.json")
    }

    static let file = JSONFile<CycleStatus>(url: StatusStore.url)

    public static func load() -> CycleStatus { file.load(default: CycleStatus()) }

    /// Best-effort: a status write must never take down a cycle that otherwise succeeded.
    public static func save(_ status: CycleStatus) {
        var s = status
        s.updatedAt = Date()
        try? file.save(s)
    }
}
