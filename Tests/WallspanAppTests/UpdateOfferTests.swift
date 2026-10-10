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
        XCTAssertEqual(InstallSource.homebrewCask(.stable).upgradeCommand,
                       "brew upgrade --cask wallspan")
        XCTAssertEqual(InstallSource.homebrewCask(.beta).upgradeCommand,
                       "brew upgrade --cask wallspan@beta")
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
                           app: "0.1.0", appSource: .homebrewCask(.stable))
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
        let made = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallspanAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        // Resolved up front, so /var and /private/var cannot make one path compare as two.
        root = made.resolvingSymlinksInPath()
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

    // MARK: - cask tracks

    private var prefixes: [String] { [root.path] }
    private var thisApp: URL { root.appendingPathComponent("This.app") }

    private func caskroom(_ token: String, linkingTo app: URL? = nil) throws {
        let version = root.appendingPathComponent("Caskroom/\(token)/0.2.0-beta.1")
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        if let app {
            try FileManager.default.createSymbolicLink(
                at: version.appendingPathComponent("Wallspan.app"), withDestinationURL: app)
        }
    }

    func testCLILinkedIntoEachCaskroom() throws {
        _ = try file("Caskroom/wallspan@beta/0.2.0-beta.1/wallspan")
        let beta = try link("bin/wallspan", to: "../Caskroom/wallspan@beta/0.2.0-beta.1/wallspan")
        XCTAssertEqual(InstallSource.cli(beta, ownBundle: thisApp, brewPrefixes: prefixes),
                       .homebrewCask(.beta))
        XCTAssertTrue(InstallSource.isCaskLink(beta, brewPrefixes: prefixes))
        XCTAssertEqual(InstallSource.cli(beta, ownBundle: thisApp, brewPrefixes: prefixes)
                       .upgradeCommand, "brew upgrade --cask wallspan@beta")
        try FileManager.default.removeItem(at: beta)

        _ = try file("Caskroom/wallspan/0.1.0/wallspan")
        let stable = try link("bin/wallspan", to: "../Caskroom/wallspan/0.1.0/wallspan")
        XCTAssertEqual(InstallSource.cli(stable, ownBundle: thisApp, brewPrefixes: prefixes),
                       .homebrewCask(.stable))
    }

    func testTokensMustMatchExactly() throws {
        _ = try file("Caskroom/wallspan@beta2/1.0/wallspan")
        let cask = try link("bin/wallspan", to: "../Caskroom/wallspan@beta2/1.0/wallspan")
        XCTAssertEqual(InstallSource.cli(cask, ownBundle: thisApp, brewPrefixes: prefixes), .other)
        XCTAssertEqual(InstallSource.cli(try file("Cellar/wallspan@beta2/1.0/bin/wallspan")),
                       .other)
        XCTAssertEqual(InstallSource.cli(try file("Cellar/wallspan@beta/1.0/bin/wallspan")),
                       .other)
    }

    func testHelperLinkWithBothCaskroomsNeedsTheCaskroomLink() throws {
        let app = root.appendingPathComponent("Applications/Wallspan.app")
        _ = try file("Applications/Wallspan.app/Contents/Helpers/wallspan")
        let linked = try link("bin/wallspan", to: app.path + "/Contents/Helpers/wallspan")

        try caskroom("wallspan@beta")
        XCTAssertEqual(InstallSource.caskLinkTrack(linked, brewPrefixes: prefixes), .beta)
        try caskroom("wallspan")
        XCTAssertNil(InstallSource.caskLinkTrack(linked, brewPrefixes: prefixes))
        let beta = root.appendingPathComponent("Caskroom/wallspan@beta")
        try FileManager.default.removeItem(at: beta)
        try caskroom("wallspan@beta", linkingTo: app)
        XCTAssertEqual(InstallSource.caskLinkTrack(linked, brewPrefixes: prefixes), .beta)
    }

    func testAppPrefersTheCaskroomThatLinksToIt() throws {
        try caskroom("wallspan")
        try caskroom("wallspan@beta", linkingTo: thisApp)
        try FileManager.default.createDirectory(at: thisApp, withIntermediateDirectories: true)
        XCTAssertEqual(InstallSource.app(thisApp, brewPrefixes: prefixes), .homebrewCask(.beta))
    }

    func testAppFallsBackToTheInstallLocationOnlyWithOneCaskroom() throws {
        try caskroom("wallspan@beta")
        XCTAssertEqual(InstallSource.app(thisApp, brewPrefixes: prefixes,
                                         installedAt: thisApp.path), .homebrewCask(.beta))
        XCTAssertEqual(InstallSource.app(thisApp, brewPrefixes: prefixes,
                                         installedAt: "/Applications/Wallspan.app"), .other)
        try caskroom("wallspan")
        XCTAssertEqual(InstallSource.app(thisApp, brewPrefixes: prefixes,
                                         installedAt: thisApp.path), .other)
    }
}
