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

/// User text headed for the log. Redacted on construction and the raw text
/// is not kept: nothing — no interpolation, `dump()`, debugger or future
/// "capture mode" — can print what the user typed. Typed text never reaches
/// the log file, because in a terminal a password prompt is indistinguishable
/// from ordinary input; support asks the user for the word instead.
struct Sensitive: CustomStringConvertible {
    let description: String

    init(_ text: String) {
        description = LogRedactor.redact(text)
    }
}
