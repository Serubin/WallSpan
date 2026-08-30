// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import Foundation

/// A directory of wallpapers walked in shuffled or sequential order. Shuffle is a bag —
/// shuffle the list, consume to exhaustion, reshuffle — so every image appears once per
/// pass instead of clumping the way independent draws would.
public struct Playlist {
    public let directory: URL
    public private(set) var order: [URL]
    public private(set) var index: Int
    public let shuffled: Bool
    /// Recorded so a config change to `recursive` can be detected and the playlist rebuilt.
    public let recursiveScan: Bool

    public enum PlaylistError: Error, CustomStringConvertible {
        case notADirectory(URL)
        case empty(URL)

        public var description: String {
            switch self {
            case .notADirectory(let u): return "not a directory: \(u.path)"
            case .empty(let u): return "no decodable images found in \(u.path)"
            }
        }
    }

    public static func scan(_ directory: URL, recursive: Bool) throws -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue
        else { throw PlaylistError.notADirectory(directory) }

        let keys: [URLResourceKey] = [.isRegularFileKey]
        var found: [URL] = []
        if recursive {
            let e = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            while let u = e?.nextObject() as? URL {
                if ImageLoader.isSupportedImage(u) { found.append(u) }
            }
        } else {
            let items = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            )
            found = items.filter { ImageLoader.isSupportedImage($0) }
        }
        return found.sorted { $0.path < $1.path }
    }

    public init(directory: URL, recursive: Bool, shuffled: Bool, resuming state: WallspanState?) throws {
        let files = try Playlist.scan(directory, recursive: recursive)
        guard !files.isEmpty else { throw PlaylistError.empty(directory) }
        self.directory = directory
        self.shuffled = shuffled
        self.recursiveScan = recursive

        // Resume only if the saved order still describes this directory and these files.
        let saved = state?.playlistOrder.map { $0.map(URL.init(fileURLWithPath:)) }
        if state?.playlistDirectory == directory.path,
           let saved, Set(saved.map(\.path)) == Set(files.map(\.path)) {
            self.order = saved
            // 0...count, not 0..<count: advance() persists after next(), so a completed
            // pass saves `count`; clamping down would replay the last image and skip the
            // reshuffle. The lower bound guards a hand-edited state.json.
            self.index = min(max(state?.playlistIndex ?? 0, 0), saved.count)
        } else {
            self.order = shuffled ? files.shuffled() : files
            self.index = 0
        }
    }

    /// Returns the current image and advances, reshuffling when the bag empties.
    public mutating func next() -> URL {
        if index >= order.count {
            if shuffled { order.shuffle() }
            index = 0
        }
        let url = order[index]
        index += 1
        return url
    }

    public func persist(into state: inout WallspanState) {
        state.playlistDirectory = directory.path
        state.playlistOrder = order.map(\.path)
        state.playlistIndex = index
    }
}
