// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import Foundation

/// Stops two `cycle` processes running at once.
///
/// Two instances each drive `setDesktopImageURL` and each write `state.json`, so they
/// interleave wallpapers and corrupt each other's playlist position. Installing the agent
/// makes that easy to hit by accident — running `cycle` by hand to try something is enough.
///
/// `flock` rather than a pidfile: the kernel releases it when the process dies, so a
/// crashed or force-killed instance leaves nothing to clean up and no stale lock to
/// second-guess.
public final class InstanceLock {
    private let fd: Int32
    public let path: URL

    private init(fd: Int32, path: URL) {
        self.fd = fd
        self.path = path
    }

    public enum LockError: Error, CustomStringConvertible {
        case cannotOpen(URL, Int32)
        case heldBy(pid: String, path: URL)

        public var description: String {
            switch self {
            case .cannotOpen(let u, let e):
                return "cannot open lock file \(u.path): errno \(e)"
            case .heldBy(let pid, _):
                return """
                another `wallspan cycle` is already running\(pid.isEmpty ? "" : " (pid \(pid))").
                       Two instances fight over the wallpaper and corrupt the saved playlist
                       position. Stop that one first, or `wallspan agent status` if it is the
                       background agent.
                """
            }
        }
    }

    public static var defaultPath: URL {
        StateStore.supportDirectory.appendingPathComponent("cycle.lock")
    }

    /// Takes the lock, or throws if another process holds it. The lock lives as long as the
    /// returned object — keep a strong reference for the life of the process.
    public static func acquire(at path: URL = defaultPath) throws -> InstanceLock {
        try StateStore.ensureDirectories()
        let fd = open(path.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw LockError.cannotOpen(path, errno) }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let holder = (try? String(contentsOf: path, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            close(fd)
            throw LockError.heldBy(pid: holder, path: path)
        }

        // Record our pid so the next caller can name who is holding it. Advisory only —
        // flock is what actually enforces exclusion.
        ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }

        return InstanceLock(fd: fd, path: path)
    }

    /// Releasing on deinit covers the normal exits; the kernel covers the abnormal ones.
    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
