import XCTest
@testable import LatCyr

final class KeyFlowDiagnosticsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testFirstKeyDownReportedOnce() {
        var diagnostics = KeyFlowDiagnostics(startedAt: start, secureInput: false)
        XCTAssertEqual(diagnostics.recordKeyDown(at: start.addingTimeInterval(3)), .firstKeyDown(after: 3))
        XCTAssertNil(diagnostics.recordKeyDown(at: start.addingTimeInterval(4)))
    }

    func testSilenceReportedOnceAfterThreshold() {
        var diagnostics = KeyFlowDiagnostics(startedAt: start, secureInput: true)
        let threshold = KeyFlowDiagnostics.silenceThreshold
        XCTAssertEqual(diagnostics.tick(now: start.addingTimeInterval(threshold - 1), secureInput: true), [])
        XCTAssertEqual(diagnostics.tick(now: start.addingTimeInterval(threshold), secureInput: true),
                       [.noKeysSinceStart(secureInput: true)])
        XCTAssertEqual(diagnostics.tick(now: start.addingTimeInterval(threshold * 2), secureInput: true), [])
    }

    func testNoSilenceReportAfterKeysArrived() {
        var diagnostics = KeyFlowDiagnostics(startedAt: start, secureInput: false)
        _ = diagnostics.recordKeyDown(at: start.addingTimeInterval(1))
        XCTAssertEqual(diagnostics.tick(now: start.addingTimeInterval(KeyFlowDiagnostics.silenceThreshold), secureInput: false), [])
    }

    func testSecureInputChangesReportedOnTransitionsOnly() {
        var diagnostics = KeyFlowDiagnostics(startedAt: start, secureInput: false)
        _ = diagnostics.recordKeyDown(at: start)
        XCTAssertEqual(diagnostics.tick(now: start.addingTimeInterval(5), secureInput: false), [])
        XCTAssertEqual(diagnostics.tick(now: start.addingTimeInterval(10), secureInput: true), [.secureInputChanged(true)])
        XCTAssertEqual(diagnostics.tick(now: start.addingTimeInterval(15), secureInput: true), [])
        XCTAssertEqual(diagnostics.tick(now: start.addingTimeInterval(20), secureInput: false), [.secureInputChanged(false)])
    }
}

final class SecureInputHolderTests: XCTestCase {
    func testPrefersSessionOnConsole() {
        let users: [[String: Any]] = [
            [SecureInputHolder.pidKey: NSNumber(value: 11), SecureInputHolder.onConsoleKey: NSNumber(value: false)],
            [SecureInputHolder.pidKey: NSNumber(value: 22), SecureInputHolder.onConsoleKey: NSNumber(value: true)],
        ]
        XCTAssertEqual(SecureInputHolder.pid(fromConsoleUsers: users), 22)
    }

    func testFallsBackToAnySessionWithPID() {
        let users: [[String: Any]] = [
            [SecureInputHolder.onConsoleKey: NSNumber(value: true)],
            [SecureInputHolder.pidKey: NSNumber(value: 33)],
        ]
        XCTAssertEqual(SecureInputHolder.pid(fromConsoleUsers: users), 33)
    }

    func testNilWhenNobodyHoldsIt() {
        XCTAssertNil(SecureInputHolder.pid(fromConsoleUsers: [[SecureInputHolder.onConsoleKey: NSNumber(value: true)]]))
        XCTAssertNil(SecureInputHolder.pid(fromConsoleUsers: []))
    }
}
