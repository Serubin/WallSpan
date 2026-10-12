// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import XCTest
@testable import WallspanApp

final class UpdateOfferTests: XCTestCase {
    private func builds(cli: String? = nil, cliSource: InstallSource = .other,
                        app: String? = nil, appSource: InstallSource = .other) -> LocalBuilds {
        LocalBuilds(cli: cli.flatMap(SemanticVersion.init), cliSource: cliSource,
                    app: app.flatMap(SemanticVersion.init), appSource: appSource)
    }

    func testUpgradeCommands() {
        XCTAssertEqual(InstallSource.homebrewFormula.upgradeCommand, "brew upgrade wallspan")
        XCTAssertEqual(InstallSource.homebrewCask.upgradeCommand, "brew upgrade --cask wallspan")
        XCTAssertNil(InstallSource.bundledWithApp.upgradeCommand)
        XCTAssertNil(InstallSource.other.upgradeCommand)
    }

    func testReleaseURLIsBuiltLocallyAndGated() {
        XCTAssertEqual(UpdateChecker.releaseURL(tag: "v0.2.0")?.absoluteString,
                       "https://github.com/Serubin/WallSpan/releases/tag/v0.2.0")
        XCTAssertNil(UpdateChecker.releaseURL(tag: "v0.2.0/../../x"))
        XCTAssertNil(UpdateChecker.releaseURL(tag: "v0.2.0-a?b"))
    }

    func testFormulaCLIBehind() throws {
        let offer = try XCTUnwrap(UpdateOffer.make(
            tag: "v0.2.0", builds: builds(cli: "0.1.0", cliSource: .homebrewFormula)
        ))
        XCTAssertEqual(offer.latest, SemanticVersion("0.2.0"))
        XCTAssertEqual(offer.commands, ["brew upgrade wallspan"])
        XCTAssertEqual(offer.behind, "the wallspan CLI is 0.1.0")
        XCTAssertEqual(offer.releaseURL.lastPathComponent, "v0.2.0")
    }

    func testBundledCLIInheritsTheAppsSourceAndCommandsAreDeduplicated() throws {
        let offer = try XCTUnwrap(UpdateOffer.make(
            tag: "v0.2.0",
            builds: builds(cli: "0.1.0", cliSource: .bundledWithApp,
                           app: "0.1.0", appSource: .homebrewCask)
        ))
        XCTAssertEqual(offer.commands, ["brew upgrade --cask wallspan"])
        XCTAssertEqual(offer.behind, "the wallspan CLI is 0.1.0, and this app is 0.1.0")
    }

    func testOnlyTheHalfThatIsBehindIsReported() throws {
        let offer = try XCTUnwrap(UpdateOffer.make(
            tag: "v0.2.0",
            builds: builds(cli: "0.2.0", cliSource: .homebrewFormula,
                           app: "0.1.0", appSource: .other)
        ))
        XCTAssertEqual(offer.commands, [])
        XCTAssertEqual(offer.behind, "this app is 0.1.0")
    }

    func testNoOfferWhenCurrentAheadUnknownOrImplausible() {
        XCTAssertNil(UpdateOffer.make(tag: "v0.2.0", builds: builds(cli: "0.2.0")))
        XCTAssertNil(UpdateOffer.make(tag: "v0.2.0", builds: builds(cli: "0.3.0-snapshot.4")))
        XCTAssertNil(UpdateOffer.make(tag: "v0.2.0", builds: builds()))
        XCTAssertNil(UpdateOffer.make(tag: "latest", builds: builds(cli: "0.1.0")))
        XCTAssertNil(UpdateOffer.make(tag: "v0.2.0-a b", builds: builds(cli: "0.1.0")))
    }

    func testOldestIsTheFurthestBehindHalf() {
        XCTAssertEqual(builds(cli: "0.2.0", app: "0.1.0").oldest, SemanticVersion("0.1.0"))
        XCTAssertEqual(builds(app: "0.1.0").oldest, SemanticVersion("0.1.0"))
        XCTAssertNil(builds().oldest)
    }
}

final class InstallSourceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallspanAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func file(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    private func link(_ relative: String, to destination: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path,
                                                   withDestinationPath: destination)
        return url
    }

    func testHomebrewFormulaThroughARelativeLinkAndASecondHop() throws {
        _ = try file("Cellar/wallspan/0.1.0/bin/wallspan")
        let brewLink = try link("bin/wallspan", to: "../Cellar/wallspan/0.1.0/bin/wallspan")
        let userLink = try link("local/bin/wallspan", to: brewLink.path)

        XCTAssertEqual(InstallSource.cli(brewLink), .homebrewFormula)
        XCTAssertEqual(InstallSource.cli(userLink), .homebrewFormula)
    }

    func testOtherCopiesAreNotMistakenForHomebrew() throws {
        XCTAssertEqual(InstallSource.cli(try file("bin/wallspan")), .other)
        XCTAssertEqual(InstallSource.cli(try file("Cellar/other/1.0/bin/wallspan")), .other)
    }
}
