import XCTest
@testable import WallspanApp

final class CLIRunnerCaptureTests: XCTestCase {
    private let sh = URL(fileURLWithPath: "/bin/sh")

    func testReturnsStdoutAndStatus() throws {
        let result = try CLIRunner.capture(sh, ["-c", "printf hello; exit 3"], timeout: 5)
        XCTAssertEqual(result.stdout, "hello")
        XCTAssertEqual(result.status, 3)
    }

    func testDrainsMoreThanAPipeBuffer() throws {
        let result = try CLIRunner.capture(
            sh, ["-c", "head -c 200000 /dev/zero | tr '\\0' a"], timeout: 10)
        XCTAssertEqual(result.stdout.count, 200_000)
    }

    func testKillsAChildThatOutlivesTheTimeout() {
        let start = Date()
        XCTAssertThrowsError(try CLIRunner.capture(sh, ["-c", "sleep 10"], timeout: 0.5)) {
            guard case CLIRunner.RunError.timedOut = $0 else {
                return XCTFail("expected timedOut, got \($0)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testKillsAChildThatIgnoresSIGTERM() throws {
        // A unique duration lets one pattern find both the shell and its sleep.
        let marker = "sleep 9.\(Int.random(in: 100_000...999_999))"
        XCTAssertThrowsError(try CLIRunner.capture(
            sh, ["-c", "trap '' TERM; \(marker); true"], timeout: 0.5))
        Thread.sleep(forTimeInterval: 0.2)
        let survivors = try CLIRunner.capture(
            URL(fileURLWithPath: "/usr/bin/pgrep"), ["-f", marker], timeout: 5)
        XCTAssertEqual(survivors.stdout, "")
    }

    func testReturnsWhenAGrandchildHoldsStdoutOpen() throws {
        let start = Date()
        let result = try CLIRunner.capture(sh, ["-c", "printf ok; sleep 5 & exit 0"], timeout: 10)
        XCTAssertEqual(result.stdout, "ok")
        XCTAssertEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}
