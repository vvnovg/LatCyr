import XCTest
@testable import LatCyr

final class CarryBufferTests: XCTestCase {
    func testAccumulatesInTypingOrder() {
        var buffer = CarryBuffer()
        buffer.append("b", layoutIsRussian: false, variant: .pc)
        buffer.append("d", layoutIsRussian: false, variant: .pc)
        XCTAssertEqual(buffer.carried(layoutIsRussian: false, variant: .pc), ["b", "d"])
    }

    func testResetClearsChain() {
        var buffer = CarryBuffer()
        buffer.append("d", layoutIsRussian: false, variant: .pc)
        buffer.reset()
        XCTAssertEqual(buffer.carried(layoutIsRussian: false, variant: .pc), [])
    }

    // The chain describes text typed under one layout. A word typed after a
    // manual layout switch starts a new chain rather than extending one that
    // no longer matches what is on screen.
    func testLayoutMismatchStartsFreshChain() {
        var buffer = CarryBuffer()
        buffer.append("b", layoutIsRussian: false, variant: .pc)
        buffer.append("шт", layoutIsRussian: true, variant: .pc)
        XCTAssertEqual(buffer.carried(layoutIsRussian: true, variant: .pc), ["шт"])
    }

    func testVariantMismatchStartsFreshChain() {
        var buffer = CarryBuffer()
        buffer.append("d", layoutIsRussian: false, variant: .pc)
        buffer.append("c", layoutIsRussian: false, variant: .apple)
        XCTAssertEqual(buffer.carried(layoutIsRussian: false, variant: .apple), ["c"])
    }

    // Reading with the wrong layout or variant yields nothing — the caller
    // must never correct text that was typed under different conditions.
    func testCarriedIsEmptyForOtherLayoutOrVariant() {
        var buffer = CarryBuffer()
        buffer.append("d", layoutIsRussian: false, variant: .pc)
        XCTAssertEqual(buffer.carried(layoutIsRussian: true, variant: .pc), [])
        XCTAssertEqual(buffer.carried(layoutIsRussian: false, variant: .apple), [])
    }

    // Overflow drops from the front, never the back: the chain has to stay
    // contiguous with the word that follows it, or the span it is matched
    // against would have a hole in the middle.
    func testOverflowDropsOldestKeepingChainContiguous() {
        var buffer = CarryBuffer()
        for word in ["b", "d", "yf", "gj"] {
            buffer.append(word, layoutIsRussian: false, variant: .pc)
        }
        XCTAssertEqual(buffer.carried(layoutIsRussian: false, variant: .pc), ["d", "yf", "gj"])
        XCTAssertEqual(CarryBuffer.maxWords, 3)
    }
}
