import XCTest
@testable import LatCyr

final class LogTests: XCTestCase {
    private var lines: [String] = []
    private var savedFrontmostAppID: (() -> String)!

    override func setUp() {
        lines = []
        savedFrontmostAppID = Log.frontmostAppID
        Log.frontmostAppID = { "test.app" }
        Log.sink = { [unowned self] in self.lines.append($0) }
        Log.level = .debug
    }

    override func tearDown() {
        Log.level = .off
        Log.sink = nil
        Log.frontmostAppID = savedFrontmostAppID
    }

    // MARK: LogMessage

    func testSensitiveIsRedactedByDefault() {
        let message: LogMessage = "word \(Sensitive("привет"))"
        XCTAssertEqual(message.text, "word [6 cyr]")
    }

    func testSensitiveKeepsNoRawText() {
        // No stored property may hold the raw word: dump(), the debugger
        // and any future code path read through Mirror, not description.
        let children = Mirror(reflecting: Sensitive("привет")).children.map { "\($0.value)" }
        XCTAssertEqual(children, ["[6 cyr]"])
    }

    func testOtherInterpolationsPassThrough() {
        let message: LogMessage = "n=\(3) ok=\(true) id=\("com.apple.Terminal")"
        XCTAssertEqual(message.text, "n=3 ok=true id=com.apple.Terminal")
    }

    func testPlainLiteral() {
        let message: LogMessage = "plain"
        XCTAssertEqual(message.text, "plain")
    }

    // MARK: LogLine

    func testLineFormat() {
        let line = LogLine.format(
            date: Date(timeIntervalSince1970: 0), level: .debug, app: "x.y",
            message: "a\nb\rc", timeZone: TimeZone(secondsFromGMT: 3 * 3600)!
        )
        XCTAssertEqual(line, "1970-01-01T03:00:00.000+03:00 DEBUG [x.y] a\\nb\\rc")
    }

    // MARK: Log facade

    func testEmitWritesFormattedLine() {
        Log.info("hello")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasSuffix(" INFO [test.app] hello"), lines[0])
    }

    func testMessageBelowLevelIsNotEvaluated() {
        Log.level = .error
        var evaluated = false
        func make() -> LogMessage {
            evaluated = true
            return "x"
        }
        Log.debug(make())
        Log.info(make())
        XCTAssertFalse(evaluated)
        XCTAssertTrue(lines.isEmpty)
    }

    func testErrorPassesAtErrorLevel() {
        Log.level = .error
        Log.error("boom")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains(" ERROR [test.app] boom"))
    }

    func testOffWritesNothing() {
        Log.level = .off
        Log.error("boom")
        Log.header(["h"])
        XCTAssertTrue(lines.isEmpty)
    }

    func testHeaderIsWrittenAtErrorLevel() {
        Log.level = .error
        Log.header(["first", "second"])
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix(" INFO [test.app] first"))
        XCTAssertTrue(lines[1].hasSuffix(" INFO [test.app] second"))
    }

    func testRepeatedHeaderLinesAreMarkedAndNotWritten() {
        Log.level = .error
        let repeated = Log.repeatedHeaderLines(["first", "second"])
        XCTAssertTrue(lines.isEmpty)
        XCTAssertEqual(repeated.count, 2)
        XCTAssertTrue(repeated[0].hasSuffix(" INFO [test.app] (header repeated after rotation) first"), repeated[0])
        XCTAssertTrue(repeated[1].hasSuffix(" INFO [test.app] (header repeated after rotation) second"), repeated[1])
    }

    func testNoSinkWritesNothingAndDoesNotEvaluate() {
        Log.sink = nil
        var evaluated = false
        func make() -> LogMessage {
            evaluated = true
            return "x"
        }
        Log.error(make())
        XCTAssertFalse(evaluated)
    }
}
