import Foundation

/// Replaces user text with what support actually needs to diagnose a
/// detection problem — its length and alphabet — so the log file never
/// becomes a record of what the user typed.
enum LogRedactor {
    static func redact(_ text: String) -> String {
        var hasCyrillic = false
        var hasLatin = false
        for ch in text where ch.isLetter {
            if ch.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) {
                hasCyrillic = true
            } else {
                hasLatin = true
            }
        }
        let alphabet: String
        switch (hasCyrillic, hasLatin) {
        case (true, true): alphabet = "mix"
        case (true, false): alphabet = "cyr"
        case (false, true): alphabet = "lat"
        case (false, false): alphabet = "none"
        }
        return "[\(text.count) \(alphabet)]"
    }
}

/// User text headed for the log. Only `LogMessage`'s own interpolation may
/// print `text` as-is, and only while typed-text capture is on; every other
/// way of turning this into a string goes through `description`, which is
/// redacted. Safe by default: forgetting the capture check can't leak.
struct Sensitive: CustomStringConvertible {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var description: String { LogRedactor.redact(text) }
}
