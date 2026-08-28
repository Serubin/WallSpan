// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import CryptoKit
import Foundation

/// SHA-256 of a canonical string, as lowercase hex. Backs the layout fingerprints and the
/// render cache key - a stable name, not a security primitive.
func sha256Hex(_ canonical: String) -> String {
    SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
}
