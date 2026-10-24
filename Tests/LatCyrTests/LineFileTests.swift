import XCTest
@testable import LatCyr

/// LineFile on a temporary directory. The user's exception file is edited
/// by hand too ("Показать файл исключений в Finder"), and an editor may save
/// it without a trailing newline.
final class LineFileTests: XCTestCase {
    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("exceptions.txt") }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("LineFileTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAppendCreatesDirectoryAndFile() {
        LineFile.append("если", to: file)
        XCTAssertEqual(LineFile.read(file), ["если"])
    }

    func testAppendAddsALine() {
        LineFile.append("jdbc", to: file)
        LineFile.append("если", to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "jdbc\nесли\n")
    }

    // Seen live: a hand-edited file ended in "jdbc" with no newline, and the
    // next word was glued to it — «jdbcесли», neither word an exception.
    func testAppendAfterLastLineWithoutNewlineStartsANewLine() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "шлюз\njdbc".write(to: file, atomically: true, encoding: .utf8)
        LineFile.append("если", to: file)
        XCTAssertEqual(LineFile.read(file), ["шлюз", "jdbc", "если"])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "шлюз\njdbc\nесли\n")
    }

    func testAppendToEmptyFileAddsNoBlankLine() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "".write(to: file, atomically: true, encoding: .utf8)
        LineFile.append("если", to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "если\n")
    }
}
