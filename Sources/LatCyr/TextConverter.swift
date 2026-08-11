import Foundation

/// Pure bidirectional converter between QWERTY (Latin) and ЙЦУКЕН (Cyrillic).
/// Digits and symbols are left untouched. Case is preserved.
public enum TextConverter {
    private static let latinToCyrillic: [Character: Character] = [
        "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е", "y": "н",
        "u": "г", "i": "ш", "o": "щ", "p": "з", "[": "х", "]": "ъ",
        "a": "ф", "s": "ы", "d": "в", "f": "а", "g": "п", "h": "р",
        "j": "о", "k": "л", "l": "д", ";": "ж", "'": "э",
        "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и", "n": "т",
        "m": "ь", ",": "б", ".": "ю", "/": ".",
    ]

    private static let cyrillicToLatin: [Character: Character] = {
        var result: [Character: Character] = [:]
        for (latin, cyrillic) in latinToCyrillic {
            result[cyrillic] = latin
        }
        return result
    }()

    public static func toCyrillic(_ text: String) -> String {
        convert(text, using: latinToCyrillic)
    }

    public static func toLatin(_ text: String) -> String {
        convert(text, using: cyrillicToLatin)
    }

    private static func convert(_ text: String, using table: [Character: Character]) -> String {
        String(text.map { char in
            let lower = Character(char.lowercased())
            guard let mapped = table[lower] else { return char }
            return char.isUppercase ? Character(mapped.uppercased()) : mapped
        })
    }
}
