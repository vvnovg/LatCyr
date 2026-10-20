import Foundation

/// Pure bidirectional converter between QWERTY (Latin) and ЙЦУКЕН (Cyrillic).
/// Digits and symbols are left untouched. Case is preserved.
public enum TextConverter {
    /// macOS ships (at least) two Russian keyboard layouts with different
    /// physical mappings for `, ~, \, |, and / — "Russian - PC"
    /// (com.apple.keylayout.RussianWin, the Windows-standard ЙЦУКЕН) and
    /// "Russian" (com.apple.keylayout.Russian, Apple's own layout). All 26
    /// letter keys and [/] are identical between them; see
    /// docs/superpowers/specs/2026-08-13-russian-keyboard-variant-design.md
    /// for how this was verified against a real Mac.
    public enum RussianKeyboardVariant: Equatable {
        case pc     // "Russian - PC" (RussianWin)
        case apple  // "Russian" (Apple's own layout)
    }

    private static let sharedLatinToCyrillic: [Character: Character] = [
        "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е", "y": "н",
        "u": "г", "i": "ш", "o": "щ", "p": "з", "[": "х", "]": "ъ",
        "a": "ф", "s": "ы", "d": "в", "f": "а", "g": "п", "h": "р",
        "j": "о", "k": "л", "l": "д", ";": "ж", "'": "э",
        "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и", "n": "т",
        "m": "ь", ",": "б", ".": "ю",
    ]

    private static let pcOverlay: [Character: Character] = ["`": "ё", "~": "Ё", "/": "."]
    private static let appleOverlay: [Character: Character] = ["\\": "ё", "|": "Ё"]

    private static let latinToCyrillicPC = sharedLatinToCyrillic.merging(pcOverlay) { a, _ in a }
    private static let latinToCyrillicApple = sharedLatinToCyrillic.merging(appleOverlay) { a, _ in a }

    private static let cyrillicToLatinPC = invert(latinToCyrillicPC)
    private static let cyrillicToLatinApple = invert(latinToCyrillicApple)

    private static func invert(_ table: [Character: Character]) -> [Character: Character] {
        var result: [Character: Character] = [:]
        for (latin, cyrillic) in table {
            result[cyrillic] = latin
        }
        return result
    }

    /// Latin punctuation keys that produce a Cyrillic *letter* on the same
    /// physical key, depending on which Russian layout variant is active.
    /// When the English layout is active but the user means Russian, these
    /// arrive as punctuation, not letters — callers that walk a word
    /// character-by-character need to treat them as letters too, or the
    /// word buffer breaks before the last letter.
    public static func ambiguousLetterSymbols(for variant: RussianKeyboardVariant) -> Set<Character> {
        let base: Set<Character> = [",", ".", ";", "'", "[", "]"]
        return variant == .pc ? base.union(["`"]) : base.union(["\\"])
    }

    public static func toCyrillic(_ text: String, variant: RussianKeyboardVariant) -> String {
        convert(text, using: variant == .pc ? latinToCyrillicPC : latinToCyrillicApple)
    }

    public static func toLatin(_ text: String, variant: RussianKeyboardVariant) -> String {
        convert(text, using: variant == .pc ? cyrillicToLatinPC : cyrillicToLatinApple)
    }

    /// `replacement` with the case of each letter taken from `onScreen`, the
    /// text it replaces. The app may have changed case after the keystroke
    /// (macOS auto-capitalisation turns a typed "d" into "D"), and the
    /// conversion of the typed buffer would silently undo that ("в", not
    /// "В"). Positions where `onScreen` has no cased letter (punctuation keys
    /// that are letters in the other layout, spaces) keep the replacement's
    /// own case. Returned unchanged when the character counts differ — then
    /// positions don't correspond.
    public static func applyingCase(of onScreen: String, to replacement: String) -> String {
        let screen = Array(onScreen), target = Array(replacement)
        guard screen.count == target.count else { return replacement }
        return String(zip(screen, target).map { s, t in
            // uppercased() can widen a character ("ß" → "SS"); keep it as is then.
            let cased = s.isUppercase ? t.uppercased() : s.isLowercase ? t.lowercased() : String(t)
            return cased.count == 1 ? Character(cased) : t
        })
    }

    private static func convert(_ text: String, using table: [Character: Character]) -> String {
        String(text.map { char in
            if let mapped = table[char] { return mapped }
            let lower = Character(char.lowercased())
            guard let mapped = table[lower] else { return char }
            return char.isUppercase ? Character(mapped.uppercased()) : mapped
        })
    }
}
