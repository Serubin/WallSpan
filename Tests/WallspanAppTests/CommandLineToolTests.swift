// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import XCTest
@testable import WallspanApp

/// Every path is inside a temporary tree, so nothing here reads the real PATH, Homebrew
/// prefix or `~/.local/bin`, and no login shell is started.
final class CommandLineToolTests: XCTestCase {
    private var root: URL!
    private var localBin: URL { root.appendingPathComponent("home/.local/bin") }
    private var brew: URL { root.appendingPathComponent("opt/homebrew") }
    private var usrLocal: URL { root.appendingPathComponent("usr/local") }
    private var thisApp: URL { root.appendingPathComponent("Apps/This.app") }
    private var bundled: URL { helper(in: thisApp) }
    private var destination: URL { localBin.appendingPathComponent("wallspan") }
    private var directories: [URL] {
        [localBin, brew.appendingPathComponent("bin"), usrLocal.appendingPathComponent("bin")]
    }
    private var brewPrefixes: [String] { [brew.path, usrLocal.path] }

    override func setUpWithError() throws {
        let fm = FileManager.default
        let made = fm.temporaryDirectory
            .appendingPathComponent("WallspanAppTests-\(UUID().uuidString)")
        try fm.createDirectory(at: made, withIntermediateDirectories: true)
        // Resolved up front, so /var and /private/var cannot make one path compare as two.
        root = made.resolvingSymlinksInPath()
        for dir in directories { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try executable(bundled)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - helpers

    private func helper(in app: URL) -> URL {
        app.appendingPathComponent("Contents/Helpers/wallspan")
    }

    private func executable(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: url.path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755]
        ))
    }

    private func link(_ url: URL, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    private func caskroom() throws {
        try FileManager.default.createDirectory(
            at: brew.appendingPathComponent("Caskroom/wallspan/0.1.0"),
            withIntermediateDirectories: true
        )
    }

    private func resolution(running url: URL,
                            rejected: [BinaryResolver.Rejection] = []) throws -> BinaryResolver.Resolution {
        let version = try JSONDecoder().decode(
            Contract.Version.self, from: Data(#"{"version":"0.2.0","schema":1}"#.utf8)
        )
        return BinaryResolver.Resolution(runner: CLIRunner(binary: url), source: .path,
                                         version: version, rejected: rejected)
    }

    private func impostor(_ url: URL) -> BinaryResolver.Rejection {
        BinaryResolver.Rejection(url: url, reason: BinaryResolver.noAnswer, newer: nil)
    }

    private func detect(shellHit: URL? = nil, resolution: BinaryResolver.Resolution? = nil,
                        ownBundle: URL? = nil) -> CommandLineTool.Installed? {
        CommandLineTool.detect(
            shellHit: shellHit, resolution: resolution, bundled: bundled,
            directories: directories, destination: destination,
            ownBundle: ownBundle ?? thisApp, brewPrefixes: brewPrefixes
        )
    }

    // MARK: - detect

    func testNothingInstalled() {
        XCTAssertNil(detect())
    }

    func testOurLinkFirstOnPath() throws {
        try link(destination, to: bundled.path)
        let found = try XCTUnwrap(detect(shellHit: destination))
        XCTAssertEqual(found.url.path, destination.path)
        XCTAssertEqual(found.origin, .linkedByInstallCLI)
        XCTAssertEqual(found.pathStatus, .first)
        XCTAssertFalse(found.notWallspan)
    }

    func testOurLinkTheShellDoesNotFind() throws {
        try link(destination, to: bundled.path)
        let found = try XCTUnwrap(detect())
        XCTAssertEqual(found.origin, .linkedByInstallCLI)
        XCTAssertEqual(found.pathStatus, .notOnPath)
    }

    func testLinkIntoAnotherWallspanApp() throws {
        let other = root.appendingPathComponent("Apps/Other.app")
        try executable(helper(in: other))
        try link(destination, to: helper(in: other).path)
        let found = try XCTUnwrap(detect(shellHit: destination))
        guard case .otherWallspanApp(let app) = found.origin else {
            return XCTFail("expected another app, got \(found.origin)")
        }
        XCTAssertEqual(app.standardizedFileURL.path, other.path)
    }

    func testHomebrewFormula() throws {
        let cellar = brew.appendingPathComponent("Cellar/wallspan/0.1.0/bin/wallspan")
        try executable(cellar)
        let linked = brew.appendingPathComponent("bin/wallspan")
        try link(linked, to: "../Cellar/wallspan/0.1.0/bin/wallspan")
        let found = try XCTUnwrap(detect(shellHit: linked))
        XCTAssertEqual(found.origin, .homebrewFormula)
        XCTAssertEqual(found.pathStatus, .first)
    }

    func testCaskLinkIntoACopyThatIsNotRunning() throws {
        let installedApp = root.appendingPathComponent("Applications/Wallspan.app")
        try executable(helper(in: installedApp))
        try caskroom()
        let linked = brew.appendingPathComponent("bin/wallspan")
        try link(linked, to: helper(in: installedApp).path)
        XCTAssertEqual(try XCTUnwrap(detect(shellHit: linked)).origin, .homebrewCask)
    }

    func testCaskLinkIntoTheRunningCopy() throws {
        let installedApp = root.appendingPathComponent("Applications/Wallspan.app")
        try executable(helper(in: installedApp))
        try caskroom()
        let linked = brew.appendingPathComponent("bin/wallspan")
        try link(linked, to: helper(in: installedApp).path)
        let found = try XCTUnwrap(detect(shellHit: linked, ownBundle: installedApp))
        XCTAssertEqual(found.origin, .homebrewCask)
    }

    func testCopyInUsrLocalBin() throws {
        let copy = usrLocal.appendingPathComponent("bin/wallspan")
        try executable(copy)
        let found = try XCTUnwrap(detect(shellHit: copy))
        XCTAssertEqual(found.origin, .elsewhere)
        XCTAssertEqual(found.pathStatus, .first)
    }

    func testDanglingLinkIsNotInstalled() throws {
        let gone = helper(in: root.appendingPathComponent("Apps/Gone.app"))
        try link(destination, to: gone.path)
        XCTAssertNil(detect())
        XCTAssertNil(CommandLineTool.installedElsewhere(
            shellHit: nil, directories: directories, destination: destination
        ))
        guard case .occupiedBy(let target) = CommandLineTool.state(bundled: bundled,
                                                                    at: destination) else {
            return XCTFail("a dangling link still occupies the destination")
        }
        XCTAssertEqual(target.path, gone.path)
    }

    func testTheShellHitOutranksWellKnownDirectories() throws {
        try link(destination, to: bundled.path)
        let copy = usrLocal.appendingPathComponent("bin/wallspan")
        try executable(copy)
        let found = try XCTUnwrap(detect(shellHit: copy))
        XCTAssertEqual(found.url.path, copy.path)
        XCTAssertEqual(found.pathStatus, .first)
    }

    func testARealWallspanBehindAnImpostorIsShadowed() throws {
        let other = usrLocal.appendingPathComponent("bin/wallspan")
        try executable(other)
        let cellar = brew.appendingPathComponent("Cellar/wallspan/0.1.0/bin/wallspan")
        try executable(cellar)
        let formula = brew.appendingPathComponent("bin/wallspan")
        try link(formula, to: "../Cellar/wallspan/0.1.0/bin/wallspan")

        let found = try XCTUnwrap(detect(
            shellHit: other,
            resolution: try resolution(running: formula, rejected: [impostor(other)])
        ))
        XCTAssertEqual(found.url.path, formula.path)
        XCTAssertEqual(found.origin, .homebrewFormula)
        XCTAssertEqual(found.pathStatus, .shadowedBy(other))
        XCTAssertFalse(found.notWallspan)
    }

    func testAnImpostorAloneIsReportedAsNotWallspan() throws {
        let other = usrLocal.appendingPathComponent("bin/wallspan")
        try executable(other)
        let found = try XCTUnwrap(detect(
            shellHit: other,
            resolution: try resolution(running: bundled, rejected: [impostor(other)])
        ))
        XCTAssertEqual(found.url.path, other.path)
        XCTAssertTrue(found.notWallspan)
        XCTAssertEqual(found.pathStatus, .first)
    }

    func testANewerRejectionIsNotAnImpostor() throws {
        let other = usrLocal.appendingPathComponent("bin/wallspan")
        try executable(other)
        let newer = BinaryResolver.Rejection(
            url: other, reason: "schema 2, this app understands up to 1", newer: (2, "0.3.0")
        )
        let found = try XCTUnwrap(detect(
            shellHit: other, resolution: try resolution(running: bundled, rejected: [newer])
        ))
        XCTAssertFalse(found.notWallspan)
    }

    func testInstalledElsewhereIgnoresTheDestination() throws {
        try link(destination, to: bundled.path)
        XCTAssertNil(CommandLineTool.installedElsewhere(
            shellHit: destination, directories: directories, destination: destination
        ))
        let copy = usrLocal.appendingPathComponent("bin/wallspan")
        try executable(copy)
        XCTAssertEqual(CommandLineTool.installedElsewhere(
            shellHit: nil, directories: directories, destination: destination
        )?.path, copy.path)
    }

    // MARK: - InstallSource cask rule

    func testCaskRuleNeedsTheCaskroom() throws {
        let installedApp = root.appendingPathComponent("Applications/Wallspan.app")
        try executable(helper(in: installedApp))
        let linked = brew.appendingPathComponent("bin/wallspan")
        try link(linked, to: helper(in: installedApp).path)
        XCTAssertFalse(InstallSource.isCaskLink(linked, brewPrefixes: brewPrefixes))
        try caskroom()
        XCTAssertTrue(InstallSource.isCaskLink(linked, brewPrefixes: brewPrefixes))
        XCTAssertEqual(InstallSource.cli(linked, ownBundle: thisApp, brewPrefixes: brewPrefixes),
                       .homebrewCask)
    }

    func testCaskRuleAcceptsALinkIntoTheCaskroom() throws {
        let staged = brew.appendingPathComponent("Caskroom/wallspan/0.1.0/wallspan")
        try executable(staged)
        let linked = brew.appendingPathComponent("bin/wallspan")
        try link(linked, to: "../Caskroom/wallspan/0.1.0/wallspan")
        XCTAssertTrue(InstallSource.isCaskLink(linked, brewPrefixes: brewPrefixes))
    }

    func testCaskRuleWantsTheLinkInAPrefixBin() throws {
        try caskroom()
        let installedApp = root.appendingPathComponent("Applications/Wallspan.app")
        try executable(helper(in: installedApp))
        try link(destination, to: helper(in: installedApp).path)
        XCTAssertFalse(InstallSource.isCaskLink(destination, brewPrefixes: brewPrefixes))
    }

    func testOwnBundleWinsInInstallSource() throws {
        try caskroom()
        let linked = brew.appendingPathComponent("bin/wallspan")
        try link(linked, to: bundled.path)
        XCTAssertEqual(InstallSource.cli(linked, ownBundle: thisApp, brewPrefixes: brewPrefixes),
                       .bundledWithApp)
    }

    // MARK: - unusedReason

    func testUnusedReason() throws {
        let copy = usrLocal.appendingPathComponent("bin/wallspan")
        try executable(copy)
        try link(destination, to: bundled.path)
        let ours = try XCTUnwrap(detect(shellHit: destination))
        let theirs = try XCTUnwrap(detect(shellHit: copy))

        // Through the link, the bundled copy is the same binary.
        XCTAssertNil(ours.unusedReason(resolution: try resolution(running: bundled),
                                       preferBundled: true))
        XCTAssertEqual(theirs.unusedReason(resolution: try resolution(running: bundled),
                                           preferBundled: true),
                       "PreferBundledCLI is set")
        let rejected = BinaryResolver.Rejection(
            url: copy, reason: "schema 2, this app understands up to 1", newer: (2, nil)
        )
        XCTAssertEqual(
            theirs.unusedReason(resolution: try resolution(running: bundled, rejected: [rejected]),
                                preferBundled: false),
            "schema 2, this app understands up to 1"
        )
        XCTAssertEqual(theirs.unusedReason(resolution: try resolution(running: bundled),
                                           preferBundled: false),
                       CommandLineTool.Installed.foundSinceLaunch)
    }

    // MARK: - namedCandidates

    func testNamedCandidatesListEachPathOnce() {
        let hit = URL(fileURLWithPath: brew.path + "/bin/./wallspan")
        let candidates = BinaryResolver.namedCandidates(shellHit: hit, directories: directories)
        XCTAssertEqual(candidates.map(\.0.standardizedFileURL.path), [
            brew.appendingPathComponent("bin/wallspan").path,
            localBin.appendingPathComponent("wallspan").path,
            usrLocal.appendingPathComponent("bin/wallspan").path,
        ])
        XCTAssertEqual(candidates.map(\.1), [.path, .wellKnown, .wellKnown])
    }

    func testNamedCandidatesWithoutAShellHit() {
        let candidates = BinaryResolver.namedCandidates(shellHit: nil, directories: directories)
        XCTAssertEqual(candidates.map(\.0.path),
                       directories.map { $0.appendingPathComponent("wallspan").path })
        XCTAssertEqual(candidates.map(\.1), [.wellKnown, .wellKnown, .wellKnown])
    }
}
