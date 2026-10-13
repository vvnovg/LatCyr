import XCTest
@testable import LatCyr

final class LogSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "LogSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsAreOffAnd100MB() {
        let settings = LogSettings(defaults: defaults)
        XCTAssertEqual(settings.level, .off)
        XCTAssertEqual(settings.maxTotalBytes, 100 * 1024 * 1024)
    }

    func testLevelRoundTrips() {
        let settings = LogSettings(defaults: defaults)
        settings.level = .debug
        XCTAssertEqual(LogSettings(defaults: defaults).level, .debug)
    }

    func testMaxTotalBytesRoundTrips() {
        let settings = LogSettings(defaults: defaults)
        settings.maxTotalBytes = 10 * 1024 * 1024
        XCTAssertEqual(LogSettings(defaults: defaults).maxTotalBytes, 10 * 1024 * 1024)
    }

    func testInvalidStoredMaxFallsBackTo100MB() {
        defaults.set(12345, forKey: "logMaxTotalBytes")
        XCTAssertEqual(LogSettings(defaults: defaults).maxTotalBytes, 100 * 1024 * 1024)
    }

    func testSettingInvalidMaxStores100MB() {
        let settings = LogSettings(defaults: defaults)
        settings.maxTotalBytes = 7
        XCTAssertEqual(LogSettings(defaults: defaults).maxTotalBytes, 100 * 1024 * 1024)
    }

    func testInvalidStoredLevelFallsBackToOff() {
        defaults.set(99, forKey: "logLevel")
        XCTAssertEqual(LogSettings(defaults: defaults).level, .off)
    }

    func testLevelOrdering() {
        XCTAssertLessThan(LogLevel.off, .error)
        XCTAssertLessThan(LogLevel.error, .info)
        XCTAssertLessThan(LogLevel.info, .debug)
    }
}
