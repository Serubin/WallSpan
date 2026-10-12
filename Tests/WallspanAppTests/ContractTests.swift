// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import XCTest
@testable import WallspanApp

final class ContractTests: XCTestCase {
    private func version(_ json: String) throws -> Contract.Version {
        try JSONDecoder().decode(Contract.Version.self, from: Data(json.utf8))
    }

    private func envelope<T: Decodable>(_ type: T.Type, key: String,
                                        _ json: String) throws -> Envelope<T> {
        let decoder = JSONDecoder()
        decoder.userInfo[Envelope<T>.payloadKeyName] = key
        return try decoder.decode(Envelope<T>.self, from: Data(json.utf8))
    }

    func testSummaryNamesAPrereleaseChannel() throws {
        let v = try version(
            #"{"version":"0.2.0-dev.pr42+g1a2b3c4","channel":"dev","schema":1,"commands":[]}"#
        )
        XCTAssertEqual(v.summary, "0.2.0-dev.pr42+g1a2b3c4 (dev, schema 1)")

        let snapshot = try version(#"{"version":"0.2.0-snapshot.7","channel":"snapshot","schema":3}"#)
        XCTAssertEqual(snapshot.summary, "0.2.0-snapshot.7 (snapshot, schema 3)")
    }

    func testSummaryOmitsReleaseAndMissingChannel() throws {
        XCTAssertEqual(try version(#"{"version":"0.2.0","channel":"release","schema":1}"#).summary,
                       "0.2.0 (schema 1)")
        XCTAssertEqual(try version(#"{"version":"0.1.0","schema":1}"#).summary,
                       "0.1.0 (schema 1)")
    }

    func testVersionDefaultsWhenFieldsAreAbsentOrWrongTyped() throws {
        let v = try version(#"{"schema":"one","commands":null}"#)
        XCTAssertEqual(v.version, "unknown")
        XCTAssertEqual(v.channel, "")
        XCTAssertEqual(v.commit, "")
        XCTAssertEqual(v.schema, 0)
        XCTAssertLessThan(v.schema, Contract.minimumSchema)
        XCTAssertEqual(v.commands, [])
        XCTAssertEqual(v.summary, "unknown (schema 0)")
    }

    func testSupportsReadsTheAdvertisedCommands() throws {
        let v = try version(#"{"version":"0.2.0","schema":1,"commands":["status","arrange"]}"#)
        XCTAssertTrue(v.supports("arrange"))
        XCTAssertFalse(v.supports("calibrate"))
    }

    func testEnvelopeReadsThePayloadUnderTheRequestedKey() throws {
        let e = try envelope(Contract.Version.self, key: "version",
                             #"{"schema":1,"version":{"version":"0.2.0","schema":1}}"#)
        XCTAssertEqual(e.schema, 1)
        XCTAssertEqual(e.payload?.version, "0.2.0")
        XCTAssertNil(e.failure)
    }

    func testEnvelopeCarriesAFailureWithDefaults() throws {
        let e = try envelope(Contract.Version.self, key: "version",
                             #"{"schema":1,"error":{"code":"no_displays"}}"#)
        XCTAssertNil(e.payload)
        XCTAssertEqual(e.failure?.code, "no_displays")
        XCTAssertEqual(e.failure?.message, "wallspan reported an error with no message")
    }

    func testDisplayGuardsDensityAndDetectsACorrectedSize() throws {
        let json = #"""
        {"schema":1,"layout":{"displays":[
          {"uuid":"A","sizeMM":[600,340],"reportedSizeMM":[597,336],"pxPerMMX":0,"pxPerMMY":4},
          {"uuid":"B","sizeMM":[600,340],"reportedSizeMM":[600.01,340]}
        ]}}
        """#
        let layout = try XCTUnwrap(envelope(Contract.Layout.self, key: "layout", json).payload)
        XCTAssertEqual(layout.displays.map(\.uuid), ["A", "B"])
        XCTAssertFalse(layout.calibrated)
        XCTAssertNil(layout.anchorUUID)

        let a = layout.displays[0]
        XCTAssertEqual(a.densityX, 1)
        XCTAssertEqual(a.densityY, 4)
        XCTAssertTrue(a.sizeWasCorrected)
        XCTAssertFalse(layout.displays[1].sizeWasCorrected)
    }
}
