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

    // The apostrophe in "don't" is the "э" key under the English layout;
    // it must neither break the word nor cost a floor-level pair.
    func testCharactersOutsideAlphabetAreSkipped() {
        let m = model([(0, 1, -1), (1, 2, -2), (2, 3, -3)])
        XCTAssertEqual(m.averageLogProb("a'b"), -2, accuracy: 1e-9)
    }

    func testYoFoldsIntoYe() {
        let m = model([(0, 1, -1), (1, 2, -2), (2, 3, -3)], alphabet: "ен")
        XCTAssertEqual(m.averageLogProb("ён"), -2, accuracy: 1e-9)
        XCTAssertEqual(m.averageLogProb("Ён"), -2, accuracy: 1e-9)
    }

    func testWordWithoutAlphabetLettersScoresFloor() {
        let m = model([])
        XCTAssertEqual(m.averageLogProb(""), BigramModel.floorLogProb)
        XCTAssertEqual(m.averageLogProb("'1"), BigramModel.floorLogProb)
    }

    func testFloorIsFinite() {
        XCTAssertTrue(BigramModel.floorLogProb.isFinite)
        XCTAssertEqual(BigramModel.floorLogProb, log(1e-7), accuracy: 1e-12)
    }
}
