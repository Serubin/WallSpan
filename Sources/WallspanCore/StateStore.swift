// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import Foundation

/// What the desktop looked like before wallspan first touched it, plus playlist position.
public struct WallspanState: Codable {
    public struct Snapshot: Codable {
        public let displayID: UInt32
        /// Optional so snapshots written before this field existed still decode; `restore`
        /// falls back to `displayID` for those.
        public var uuid: String?
        public let path: String?
    }

    /// One display's position in the macOS arrangement, y-DOWN points.
    public struct ArrangementSnapshot: Codable {
        public let uuid: String
        public let name: String
        public let x: Int
        public let y: Int

        public init(uuid: String, name: String, x: Int, y: Int) {
            self.uuid = uuid; self.name = name; self.x = x; self.y = y
        }
    }

    /// Captured on first `apply`, never overwritten: `restore` returns to the
    /// pre-wallspan wallpaper, not to whatever wallspan set most recently.
    public var originalWallpaper: [Snapshot]?

    /// Same contract, for the arrangement `layout arrange --revert` puts back.
    public var originalArrangement: [ArrangementSnapshot]?
    public var playlistDirectory: String?
    public var playlistOrder: [String]?
    public var playlistIndex: Int?
    public var lastApplied: String?

    public init() {}
}

public enum StateStore {
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wallspan", isDirectory: true)
    }

    public static var stateURL: URL { supportDirectory.appendingPathComponent("state.json") }
    public static var renderDirectory: URL {
        supportDirectory.appendingPathComponent("rendered", isDirectory: true)
    }

    public static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: renderDirectory, withIntermediateDirectories: true)
    }

    public static func load() -> WallspanState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(WallspanState.self, from: data)
        else { return WallspanState() }
        return state
    }

    public static func save(_ state: WallspanState) throws {
        try ensureDirectories()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(state).write(to: stateURL, options: .atomic)
    }
}
