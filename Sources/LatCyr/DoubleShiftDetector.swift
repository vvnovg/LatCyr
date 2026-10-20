import Foundation

/// Recognises a double Shift tap: two quick press-release cycles of Shift
/// with nothing else in between. Pure — fed with already-classified
/// events and their timestamps — so it is unit-tested, unlike the event
/// tap that feeds it.
///
/// Fires on the *second release*, not the second press: a press alone
/// can still turn into Shift+letter, a release with no key in between
/// cannot.
struct DoubleShiftDetector {
    enum Input {
        case shiftDown, shiftUp
        /// Any key, or any modifier other than Shift: breaks the pair.
        case otherKey
    }

    /// Longest a single press may be held.
    static let maxPress: TimeInterval = 0.3
    /// Longest pause between the first release and the second press.
    static let maxGap: TimeInterval = 0.3

    private enum State {
        case idle
        case firstDown(at: TimeInterval)
        case firstUp(at: TimeInterval)
        case secondDown(at: TimeInterval)
    }

    private var state: State = .idle

    /// Returns true when this event completes a double Shift.
    mutating func feed(_ input: Input, at time: TimeInterval) -> Bool {
        switch (input, state) {
        case (.otherKey, _):
            state = .idle
        case (.shiftDown, .firstUp(let releasedAt)) where time - releasedAt <= Self.maxGap:
            state = .secondDown(at: time)
        case (.shiftDown, _):
            // Fresh pair: from idle, after a too-long gap, or a second
            // press without a release in between (left and right Shift).
            state = .firstDown(at: time)
        case (.shiftUp, .firstDown(let pressedAt)) where time - pressedAt <= Self.maxPress:
            state = .firstUp(at: time)
        case (.shiftUp, .secondDown(let pressedAt)) where time - pressedAt <= Self.maxPress:
            state = .idle
            return true
        case (.shiftUp, _):
            state = .idle
        }
        return false
    }
}
