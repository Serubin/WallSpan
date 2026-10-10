// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import XCTest
@testable import WallspanApp

final class UpdateCheckerTests: XCTestCase {
    private typealias Release = UpdateChecker.Release

    // MARK: - the response

    func testNewestTagPicksTheHighestOfAMixedList() {
        let releases = [
            Release(tag: "v0.2.0-beta.2", prerelease: true),
            Release(tag: "v0.1.0"),
            Release(tag: "v0.2.0-beta.10", prerelease: true),
            Release(tag: "v0.2.0-rc.1", prerelease: true),
        ]
        XCTAssertEqual(UpdateChecker.newestTag(in: releases), "v0.2.0-rc.1")
        XCTAssertEqual(UpdateChecker.newestTag(in: releases + [Release(tag: "v0.2.0")]), "v0.2.0")
    }

    func testNewestTagSkipsWhatIsNotOnTheBetaTrack() {
        let releases = [
            Release(tag: "v0.1.0"),
            Release(tag: "v0.3.0", draft: true),
            Release(tag: "v0.2.0-beta.1", draft: true, prerelease: true),
            Release(tag: "v0.2.0-unsigned.4", prerelease: true),
            Release(tag: "v0.2.0-snapshot.7", prerelease: true),
            Release(tag: "v0.4.0/../x"),
            Release(tag: "v0.5.0-beta.1-" + String(repeating: "a", count: 20), prerelease: true),
            // A flag that disagrees with the tag is something the tap would refuse too.
            Release(tag: "v0.6.0", prerelease: true),
            Release(tag: "v0.6.0-beta.1"),
            Release(tag: ""),
        ]
        XCTAssertEqual(UpdateChecker.newestTag(in: releases), "v0.1.0")
        XCTAssertNil(UpdateChecker.newestTag(in: []))
        XCTAssertNil(UpdateChecker.newestTag(in: Array(releases.dropFirst())))
    }

    func testDecodesAListOrASingleRelease() throws {
        let list = #"""
        [{"tag_name":"v0.2.0-beta.1","draft":false,"prerelease":true,"body":"…"},
         {"tag_name":"v0.1.0","draft":false,"prerelease":false},
         {"tag_name":null,"draft":"no"}]
        """#
        let decoded = try XCTUnwrap(UpdateChecker.releases(from: Data(list.utf8)))
        XCTAssertEqual(decoded, [Release(tag: "v0.2.0-beta.1", prerelease: true),
                                 Release(tag: "v0.1.0"), Release(tag: "")])
        XCTAssertEqual(UpdateChecker.newestTag(in: decoded), "v0.2.0-beta.1")

        let latest = #"{"tag_name":"v0.1.0","assets":[]}"#
        XCTAssertEqual(UpdateChecker.releases(from: Data(latest.utf8)), [Release(tag: "v0.1.0")])
        XCTAssertNil(UpdateChecker.releases(from: Data("not json".utf8)))
        XCTAssertNil(UpdateChecker.releases(from: Data("[1, 2]".utf8)))
    }

    // MARK: - the local builds

    private func builds(cli: String? = nil, channel: String = "release",
                        cliSource: InstallSource = .other, app: String? = nil,
                        appSource: InstallSource = .other) -> LocalBuilds {
        LocalBuilds.make(cliVersion: cli, cliChannel: cli == nil ? nil : channel,
                         appShortVersion: app, cliSource: cliSource, appSource: appSource)
    }

    func testAppVersionAcceptsABetaButNotDescribeOutput() {
        XCTAssertEqual(builds(app: "0.2.0-beta.1").app, SemanticVersion("0.2.0-beta.1"))
        XCTAssertEqual(builds(app: "0.2.0").app, SemanticVersion("0.2.0"))
        XCTAssertNil(builds(app: "0.1.0-3-gabc1234").app)
        XCTAssertNil(builds(app: "0.2.0-unsigned.1").app)
    }

    func testCLIChannelAllowlist() {
        for channel in ["release", "beta", "unsigned", "snapshot", "dev"] {
            XCTAssertNotNil(builds(cli: "0.2.0-beta.1", channel: channel).cli, channel)
        }
        XCTAssertNil(builds(cli: "0.2.0", channel: "local").cli)
        XCTAssertNil(builds(cli: "0.2.0", channel: "").cli)
        XCTAssertNil(builds(cli: "unknown", channel: "release").cli)
    }

    func testFollowsBetasOnAnyOneSign() {
        XCTAssertFalse(builds(cli: "0.1.0", app: "0.1.0",
                              appSource: .homebrewCask(.stable)).followsBetas)
        XCTAssertFalse(builds(cli: "0.2.0-unsigned.1", channel: "unsigned").followsBetas)
        XCTAssertFalse(builds(cli: "0.2.0-snapshot.7", channel: "snapshot").followsBetas)

        XCTAssertTrue(builds(cli: "0.2.0", channel: "beta").followsBetas)
        XCTAssertTrue(builds(cli: "0.2.0-beta.1", channel: "snapshot").followsBetas)
        XCTAssertTrue(builds(app: "0.2.0-rc.1").followsBetas)
        XCTAssertTrue(builds(cli: "0.1.0", cliSource: .homebrewCask(.beta)).followsBetas)
        XCTAssertTrue(builds(app: "0.1.0", appSource: .homebrewCask(.beta)).followsBetas)
    }

    // MARK: - the offer

    func testABetaSeenEarlierIsNotOfferedToAStableInstall() {
        let stable = builds(cli: "0.1.0", cliSource: .homebrewFormula,
                            app: "0.1.0", appSource: .homebrewCask(.stable))
        XCTAssertNil(UpdateOffer.make(tag: "v0.2.0-beta.1", builds: stable))
        XCTAssertNotNil(UpdateOffer.make(tag: "v0.2.0", builds: stable))
    }

    func testUnsignedIsNeverOffered() {
        let beta = builds(app: "0.2.0-beta.1", appSource: .homebrewCask(.beta))
        XCTAssertNil(UpdateOffer.make(tag: "v0.2.0-unsigned.1", builds: beta))
    }

    func testBetaTrackBehindAStableGetsTheBetaCask() throws {
        let offer = try XCTUnwrap(UpdateOffer.make(
            tag: "v0.2.0",
            builds: builds(cli: "0.2.0-rc.1", channel: "beta", cliSource: .bundledWithApp,
                           app: "0.2.0-rc.1", appSource: .homebrewCask(.beta))
        ))
        XCTAssertEqual(offer.commands, ["brew upgrade --cask wallspan@beta"])
    }

    func testBetaTrackBehindANewerBeta() throws {
        let offer = try XCTUnwrap(UpdateOffer.make(
            tag: "v0.2.0-beta.3",
            builds: builds(app: "0.2.0-beta.2", appSource: .homebrewCask(.beta))
        ))
        XCTAssertEqual(offer.latest, SemanticVersion("0.2.0-beta.3"))
        XCTAssertEqual(offer.commands, ["brew upgrade --cask wallspan@beta"])
        XCTAssertEqual(offer.behind, "this app is 0.2.0-beta.2")
    }

    func testABetaIsNeverOfferedThroughAStableToken() throws {
        let offer = try XCTUnwrap(UpdateOffer.make(
            tag: "v0.2.0-beta.3",
            builds: builds(cli: "0.1.0", cliSource: .homebrewFormula,
                           app: "0.2.0-beta.1", appSource: .other)
        ))
        XCTAssertEqual(offer.commands, [])
        XCTAssertEqual(offer.behind, "the wallspan CLI is 0.1.0, and this app is 0.2.0-beta.1")

        let mixed = try XCTUnwrap(UpdateOffer.make(
            tag: "v0.2.0-beta.3",
            builds: builds(cli: "0.1.0", cliSource: .homebrewFormula,
                           app: "0.2.0-beta.1", appSource: .homebrewCask(.beta))
        ))
        XCTAssertEqual(mixed.commands, ["brew upgrade --cask wallspan@beta"])
    }
}
