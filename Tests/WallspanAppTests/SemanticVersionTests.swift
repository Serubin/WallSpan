// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import XCTest
@testable import WallspanApp

final class SemanticVersionTests: XCTestCase {
    func testParsesCoreAndPrerelease() throws {
        let v = try XCTUnwrap(SemanticVersion("0.2.0-snapshot.7"))
        XCTAssertEqual([v.major, v.minor, v.patch], [0, 2, 0])
        XCTAssertEqual(v.prerelease, ["snapshot", "7"])
        XCTAssertEqual(v.description, "0.2.0-snapshot.7")
    }

    func testAcceptsTagPrefixAndSurroundingWhitespace() {
        XCTAssertEqual(SemanticVersion("v1.2.3"), SemanticVersion("1.2.3"))
        XCTAssertEqual(SemanticVersion(" 1.2.3\n"), SemanticVersion("1.2.3"))
    }

    func testDropsBuildMetadata() throws {
        let v = try XCTUnwrap(SemanticVersion("0.2.0-dev.pr42+g1a2b3c4"))
        XCTAssertEqual(v.prerelease, ["dev", "pr42"])
        XCTAssertEqual(v.description, "0.2.0-dev.pr42")
        XCTAssertEqual(SemanticVersion("0.2.0+g1"), SemanticVersion("0.2.0+g2"))
    }

    func testRejectsMalformed() {
        for raw in ["", "1", "1.2", "1.2.3.4", "a.b.c", "1..3", "-1.2.3", "1.-2.3", "vv1.2.3"] {
            XCTAssertNil(SemanticVersion(raw), raw)
        }
    }

    /// Strictly ascending, so every earlier entry must compare below every later one.
    func testPrecedence() {
        let ascending = [
            "0.1.0",
            "0.2.0-alpha",
            "0.2.0-alpha.1",
            "0.2.0-alpha.beta",
            "0.2.0-beta",
            "0.2.0-beta.2",
            "0.2.0-beta.11",
            "0.2.0-rc.1",
            "0.2.0-snapshot.7",
            "0.2.0-snapshot.10",
            "0.2.0",
            "0.2.1",
            "0.3.0-snapshot.4",
            "0.10.0",
            "1.0.0",
        ].map { SemanticVersion($0)! }

        for (i, lower) in ascending.enumerated() {
            for higher in ascending[(i + 1)...] {
                XCTAssertLessThan(lower, higher)
                XCTAssertFalse(higher < lower, "\(higher) < \(lower)")
            }
        }
    }

    /// Shared with tap.yml's Python comparison, so the app and the tap agree.
    func testBetaTrackVectors() {
        let ascending = ["0.2.0-beta.2", "0.2.0-beta.10", "0.2.0-rc.1", "0.2.0", "0.3.0-beta.1"]
            .map { SemanticVersion($0)! }
        for (lower, higher) in zip(ascending, ascending.dropFirst()) {
            XCTAssertLessThan(lower, higher)
        }
    }

    func testIsBeta() {
        for beta in ["0.2.0-beta.1", "v0.2.0-beta.10", "0.2.0-rc.1", "0.2.0-beta.1+gabc1234"] {
            XCTAssertTrue(SemanticVersion(beta)!.isBeta, beta)
        }
        for other in ["0.2.0", "0.2.0-snapshot.7", "0.1.0-3-gabc1234", "0.2.0-unsigned.1",
                      "0.2.0-beta", "0.2.0-beta.0", "0.2.0-beta.01", "0.2.0-beta.1.1",
                      "0.2.0-beta.x", "0.2.0-dev.pr42"] {
            XCTAssertFalse(SemanticVersion(other)!.isBeta, other)
        }
    }

    func testTrackableTags() {
        for tag in ["v0.2.0", "v0.2.0-beta.3", "v0.2.0-rc.1"] {
            XCTAssertTrue(SemanticVersion.isTrackable(tag), tag)
        }
        for tag in ["v0.2.0-unsigned.1", "v0.2.0-snapshot.7", "v0.2.0-beta", "latest",
                    "v0.2.0-beta.1-" + String(repeating: "a", count: 20)] {
            XCTAssertFalse(SemanticVersion.isTrackable(tag), tag)
        }
    }

    func testBuildMetadataHasNoPrecedence() {
        let a = SemanticVersion("0.2.0-snapshot.7+gaaaaaaa")!
        let b = SemanticVersion("0.2.0-snapshot.7+gbbbbbbb")!
        XCTAssertFalse(a < b)
        XCTAssertFalse(b < a)
    }

    func testPlausibleTag() {
        for tag in ["v0.2.0", "0.2.0", "v0.2.0-beta.1", "v0.2.0-snapshot.7+g1a2b3c4"] {
            XCTAssertTrue(SemanticVersion.isPlausibleTag(tag), tag)
        }
        let tooLong = "v1.0.0-" + String(repeating: "a", count: 26)
        XCTAssertEqual(tooLong.count, 33)
        for tag in ["", "latest", "../../evil", "v0.2.0/../x", "v0.2.0-bé", "v0.2.0-a b",
                    "v0.2.0-a?b", tooLong] {
            XCTAssertFalse(SemanticVersion.isPlausibleTag(tag), tag)
        }
    }
}
