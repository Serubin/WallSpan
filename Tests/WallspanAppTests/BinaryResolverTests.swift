// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import XCTest
@testable import WallspanApp

final class BinaryResolverTests: XCTestCase {
    private func version(_ json: String) throws -> Contract.Version {
        try JSONDecoder().decode(Contract.Version.self, from: Data(json.utf8))
    }

    func testSupportedSchemaIsUsable() throws {
        let v = try version(#"{"version":"0.2.0","schema":1}"#)
        guard case .usable(let usable) = BinaryResolver.classify(schema: 1, version: v) else {
            return XCTFail("schema 1 should be usable")
        }
        XCTAssertEqual(usable.version, "0.2.0")
    }

    func testAboveTheRangeIsNewer() throws {
        let v = try version(#"{"version":"0.3.0","schema":2}"#)
        let probe = BinaryResolver.classify(schema: 2, version: v)
        guard case .newer(let schema, let reported) = probe else {
            return XCTFail("schema 2 should be newer")
        }
        XCTAssertEqual(schema, 2)
        XCTAssertEqual(reported, "0.3.0")
    }

    func testNewerWinsOverAnUndecodablePayload() {
        let probe = BinaryResolver.classify(schema: 2, version: nil)
        guard case .newer(let schema, let reported) = probe else {
            return XCTFail("an undecodable payload must not hide a newer schema")
        }
        XCTAssertEqual(schema, 2)
        XCTAssertNil(reported)
    }

    func testBelowTheRangeIsOlder() throws {
        let v = try version(#"{"version":"0.0.1"}"#)
        guard case .unusable(let reason) = BinaryResolver.classify(schema: 0, version: v) else {
            return XCTFail("schema 0 should be unusable")
        }
        XCTAssertEqual(reason, "schema 0, this app needs 1 or newer")
    }

    func testOlderWinsOverAnUndecodablePayload() {
        guard case .unusable(let reason) = BinaryResolver.classify(schema: 0, version: nil) else {
            return XCTFail("schema 0 should be unusable")
        }
        XCTAssertEqual(reason, "schema 0, this app needs 1 or newer")
    }

    func testInRangeWithoutAPayloadDidNotAnswer() {
        guard case .unusable(let reason) = BinaryResolver.classify(schema: 1, version: nil) else {
            return XCTFail("a missing payload should be unusable")
        }
        XCTAssertEqual(reason, "did not answer `version --json`")
    }

    func testClassifiesAgainstTheGivenRange() throws {
        let v = try version(#"{"version":"0.3.0","schema":2}"#)
        guard case .usable = BinaryResolver.classify(schema: 2, version: v, supported: 1...2)
        else { return XCTFail("schema 2 should be usable once the range reaches it") }
        guard case .newer = BinaryResolver.classify(schema: 3, version: v, supported: 1...2)
        else { return XCTFail("schema 3 should be newer than 1...2") }
        guard case .unusable = BinaryResolver.classify(schema: 1, version: v, supported: 2...3)
        else { return XCTFail("schema 1 should be older than 2...3") }
    }

    func testResolutionSeparatesNewerRejections() throws {
        let newer = BinaryResolver.Rejection(
            url: URL(fileURLWithPath: "/opt/homebrew/bin/wallspan"),
            reason: "schema 2, this app understands up to 1", newer: (2, "0.3.0")
        )
        let broken = BinaryResolver.Rejection(
            url: URL(fileURLWithPath: "/usr/local/bin/wallspan"),
            reason: "did not answer `version --json`", newer: nil
        )
        let resolution = BinaryResolver.Resolution(
            runner: CLIRunner(binary: URL(fileURLWithPath: "/Applications/Wallspan.app/x")),
            source: .bundled,
            version: try version(#"{"version":"0.2.0","schema":1}"#),
            rejected: [newer, broken]
        )
        XCTAssertEqual(resolution.newer.map(\.url.path), ["/opt/homebrew/bin/wallspan"])
    }
}
