// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import Foundation

/// One JSON file on disk, loaded with a fallback and written atomically. Shared by the
/// three stores so their encoding and corrupt-file behaviour cannot drift apart.
public struct JSONFile<T: Codable> {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// Falls back rather than throwing: a corrupt file degrades to defaults.
    public func load(default fallback: @autoclosure () -> T) -> T {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(T.self, from: data)
        else { return fallback() }
        return value
    }

    public func save(_ value: T) throws {
        try StateStore.ensureDirectories()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(value).write(to: url, options: .atomic)
    }
}
