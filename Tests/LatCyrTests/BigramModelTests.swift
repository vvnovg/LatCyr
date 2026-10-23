import XCTest
@testable import LatCyr

final class BigramModelTests: XCTestCase {
    /// A model over `alphabet` where every cell is `fill` except `cells`,
    /// given as (from, to, logProb). Index 0 is "^", 1...N the letters,
    /// N+1 is "$" — for alphabet "ab": ^ = 0, a = 1, b = 2, $ = 3.
    private func model(_ cells: [(Int, Int, Float)], alphabet: String = "ab", fill: Float = -10) -> BigramModel {
        let size = alphabet.count + 2
        var table = [Float](repeating: fill, count: size * size)
        for (from, to, value) in cells { table[from * size + to] = value }
        return BigramModel(alphabet: alphabet, logProbs: table)
    }

    // ^a = -1, ab = -2, b$ = -3: three transitions, mean -2.
    func testAveragesEveryTransitionIncludingBoundaries() {
        let m = model([(0, 1, -1), (1, 2, -2), (2, 3, -3)])
        XCTAssertEqual(m.averageLogProb("ab"), -2, accuracy: 1e-9)
    }

    // "a" alone is ^a + a$. Only one of them is cheap in each model, so a
    // model that ignored either marker would score both words -10.
    func testWordStartAndEndAreScored() {
        XCTAssertEqual(model([(0, 1, -1)]).averageLogProb("a"), -5.5, accuracy: 1e-9)
        XCTAssertEqual(model([(1, 3, -1)]).averageLogProb("a"), -5.5, accuracy: 1e-9)
    }

    // The same letters in another order use other cells.
    func testOrderMatters() {
        let m = model([(0, 1, -1), (1, 2, -2), (2, 3, -3)])
        XCTAssertEqual(m.averageLogProb("ba"), -10, accuracy: 1e-9)
    }

    func testCaseInsensitive() {
        let m = model([(0, 1, -1), (1, 2, -2), (2, 3, -3)])
        XCTAssertEqual(m.averageLogProb("AB"), m.averageLogProb("ab"))
    }

    // A character outside the alphabet is an impossible symbol of the
    // language: both transitions through it cost the floor, and it counts
    // as a position. Skipping it instead scored "[e;t" (хуже under the
    // English layout) as the perfectly English "et".
    func testCharactersOutsideAlphabetCostTheFloor() {
        let m = model([(0, 1, -1), (1, 2, -2), (2, 3, -3)])
        let floor = BigramModel.floorLogProb
        XCTAssertEqual(m.averageLogProb("a[b"), (-1 + floor + floor - 3) / 4, accuracy: 1e-9)
        XCTAssertLessThan(m.averageLogProb("a[b"), m.averageLogProb("ab"))
    }

    func testYoFoldsIntoYe() {
        let m = model([(0, 1, -1), (1, 2, -2), (2, 3, -3)], alphabet: "ен")
        XCTAssertEqual(m.averageLogProb("ён"), -2, accuracy: 1e-9)
        XCTAssertEqual(m.averageLogProb("Ён"), -2, accuracy: 1e-9)
    }

    func testWordWithoutAlphabetLettersScoresFloor() {
        let m = model([])
        XCTAssertEqual(m.averageLogProb(""), BigramModel.floorLogProb)
        XCTAssertEqual(m.averageLogProb("'1"), BigramModel.floorLogProb, accuracy: 1e-9)
    }

    func testFloorIsFinite() {
        XCTAssertTrue(BigramModel.floorLogProb.isFinite)
        XCTAssertEqual(BigramModel.floorLogProb, log(1e-7), accuracy: 1e-12)
    }

    // Sanity checks on the generated tables, not on the detector: a broken
    // generator (transposed rows, wrong alphabet order, conditional instead
    // of joint probabilities) shows up here first. "ашду" is "file" typed
    // under the Russian layout; "ghbdtn" is "привет" typed under the English.
    func testRealTablesSeparateWordsFromLayoutGibberish() {
        XCTAssertGreaterThan(BigramModel.russian.averageLogProb("привет"), BigramModel.russian.averageLogProb("ашду") + 2)
        XCTAssertGreaterThan(BigramModel.english.averageLogProb("hello"), BigramModel.english.averageLogProb("ghbdtn") + 1)
    }

    // Every score stays at or above the floor (the literals are rounded to
    // four decimals, hence the tolerance).
    func testRealTablesStayAboveFloor() {
        for word in ["привет", "ашду", "щщщщ", "ъъъ"] {
            XCTAssertGreaterThanOrEqual(BigramModel.russian.averageLogProb(word), BigramModel.floorLogProb - 1e-3)
        }
        for word in ["hello", "qqqq", "xzxz"] {
            XCTAssertGreaterThanOrEqual(BigramModel.english.averageLogProb(word), BigramModel.floorLogProb - 1e-3)
        }
    }
}
