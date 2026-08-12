# Поддержка вариантов русской раскладки — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix wrong-layout conversion for macOS's «Russian» keyboard input source (`com.apple.keylayout.Russian`) by making `TextConverter` variant-aware — it was hardcoded to «Russian - PC» (`RussianWin`) key mappings for `` ` ``/`~`, `\`/`|`, and `/`, which differ between the two. Also fixes a related false-positive: Belarusian layout being misdetected as Russian.

**Architecture:** `TextConverter` gains a `RussianKeyboardVariant` enum (`.pc` / `.apple`) and threads it as a required parameter through `toCyrillic`/`toLatin`/`ambiguousLetterSymbols(for:)` — stays a pure function, the variant is supplied by the caller, not read from system state. `LayoutManager` gains `currentRussianVariant`, detecting `.apple` only for the exact ID `com.apple.keylayout.Russian` and falling back to `.pc` for everything else (including `Russian - PC`, `Russian-Phonetic`, and any future variant). `LanguageDetector.isWrongLayout` and `TextFieldController`'s word-boundary methods gain the same parameter. `InputMonitor` captures the variant once per word (same moment it already captures `currentLayoutIsRussian`) and threads it through every scheduling/correction call, mirroring the existing `wasRussian` threading exactly.

**Tech Stack:** Swift Package Manager, XCTest. No new dependencies.

## Global Constraints

- `com.apple.keylayout.Russian` («Russian») uses `.apple`; every other Russian-family input source ID (including `RussianWin` / «Russian - PC» and `Russian-Phonetic` / «Russian – QWERTY») falls back to `.pc` — this matches the app's existing (correct-for-PC) behavior and is a deliberate scope limit, not an oversight.
- `TextConverter` stays a pure function — `RussianKeyboardVariant` is passed in by every caller, never read from `LayoutManager`/TIS inside `TextConverter` itself.
- The 26 letter-key mappings and `[`/`]` are identical between `.pc` and `.apple` — only `` ` ``/`~`, `\`/`|`, and `/` differ; `.pc`: `` ` ``→ё, `~`→Ё, `/`→`.`; `.apple`: `\`→ё, `|`→Ё, `` ` `` and `/` unchanged (pass through).
- `TextConverter`, `LanguageDetector` — pure functions, fully unit-tested; `LayoutManager`, `InputMonitor`, `TextFieldController` — thin system wrappers, tested manually only (existing project convention).
- Every place that currently reads `TextConverter.ambiguousLetterSymbols` or calls `toCyrillic`/`toLatin` without a variant must be updated in the same task that changes the call it belongs to — no task may leave the package unable to build (lesson from the previous plan's pre-flight review: mechanically inseparable changes get one task, not two).
- Коммиты — conventional style (`feat:`, `fix:`).

---

## Task 1: `TextConverter` — `RussianKeyboardVariant`, variant-aware tables

**Files:**
- Modify: `Sources/LatCyr/TextConverter.swift` (full rewrite)
- Modify: `Tests/LatCyrTests/TextConverterTests.swift` (full rewrite)
- Modify: `Sources/LatCyr/LanguageDetector.swift:124,128` (2 lines — temporary `.pc` literal so the package still builds; replaced with the real parameter in Task 2)
- Modify: `Sources/LatCyr/InputMonitor.swift:121,209` (2 lines — same reason; replaced with the real captured value in Task 4)
- Modify: `Sources/LatCyr/TextFieldController.swift:189` (1 line — same reason; replaced with the real parameter in Task 4)
- Modify: `Tests/LatCyrTests/LanguageDetectorTests.swift:16,63,74` (3 lines — direct `TextConverter` calls need the new required parameter to compile)

**Interfaces:**
- Produces:
  - `TextConverter.RussianKeyboardVariant` (`public enum ...: Equatable { case pc, apple }`)
  - `TextConverter.toCyrillic(_ text: String, variant: RussianKeyboardVariant) -> String`
  - `TextConverter.toLatin(_ text: String, variant: RussianKeyboardVariant) -> String`
  - `TextConverter.ambiguousLetterSymbols(for variant: RussianKeyboardVariant) -> Set<Character>`

This task's non-`TextConverter` edits are **temporary compile-fix literals** (`.pc` everywhere), not real behavior — they don't change what the app does. Task 2 and Task 4 replace each literal with the real threaded value once the calling function has one to offer.

- [ ] **Step 1: Rewrite `Tests/LatCyrTests/TextConverterTests.swift`**

```swift
import XCTest
@testable import LatCyr

final class TextConverterTests: XCTestCase {
    func testToCyrillicBasic() {
        XCTAssertEqual(TextConverter.toCyrillic("ghbdtn", variant: .pc), "привет")
    }

    func testToLatinBasic() {
        XCTAssertEqual(TextConverter.toLatin("руддщ", variant: .pc), "hello")
    }

    func testToCyrillicPreservesCase() {
        XCTAssertEqual(TextConverter.toCyrillic("Ghbdtn", variant: .pc), "Привет")
        XCTAssertEqual(TextConverter.toCyrillic("GHBDTN", variant: .pc), "ПРИВЕТ")
    }

    func testToLatinPreservesCase() {
        XCTAssertEqual(TextConverter.toLatin("Руддщ", variant: .pc), "Hello")
        XCTAssertEqual(TextConverter.toLatin("РУДДЩ", variant: .pc), "HELLO")
    }

    func testDigitsAndSymbolsUntouched() {
        XCTAssertEqual(TextConverter.toCyrillic("ghbdtn123", variant: .pc), "привет123")
        XCTAssertEqual(TextConverter.toLatin("привет!", variant: .pc), "ghbdtn!")
    }

    func testAllLettersRoundTripPC() {
        let latin = "`qwertyuiop[]asdfghjkl;'zxcvbnm,./"
        let cyrillic = "ёйцукенгшщзхъфывапролджэячсмитьбю."
        XCTAssertEqual(TextConverter.toCyrillic(latin, variant: .pc), cyrillic)
        XCTAssertEqual(TextConverter.toLatin(cyrillic, variant: .pc), latin)
    }

    func testYoCasePC() {
        XCTAssertEqual(TextConverter.toCyrillic("~", variant: .pc), "Ё")
        XCTAssertEqual(TextConverter.toLatin("Ё", variant: .pc), "~")
    }

    // "Russian" (Apple's own layout, not "Russian - PC"): the 26 letters +
    // [/] are identical to .pc, but ё/Ё live on \/| instead of `/~, and `
    // and / pass through unchanged — verified against a real Mac with
    // "Russian" active (see docs/superpowers/specs/2026-08-13-russian-keyboard-variant-design.md).
    func testAllLettersRoundTripApple() {
        let latin = "qwertyuiop[]asdfghjkl;'zxcvbnm,.\\"
        let cyrillic = "йцукенгшщзхъфывапролджэячсмитьбюё"
        XCTAssertEqual(TextConverter.toCyrillic(latin, variant: .apple), cyrillic)
        XCTAssertEqual(TextConverter.toLatin(cyrillic, variant: .apple), latin)
    }

    func testYoCaseApple() {
        XCTAssertEqual(TextConverter.toCyrillic("|", variant: .apple), "Ё")
        XCTAssertEqual(TextConverter.toLatin("Ё", variant: .apple), "|")
    }

    // The two variants' overlay keys must not leak into each other.
    func testVariantsDoNotCrossContaminate() {
        // Under .pc, "\" isn't mapped — stays "\" (no ё).
        XCTAssertEqual(TextConverter.toCyrillic("\\", variant: .pc), "\\")
        // Under .apple, "`" isn't mapped — stays "`" (no ё).
        XCTAssertEqual(TextConverter.toCyrillic("`", variant: .apple), "`")
        // Under .apple, "/" isn't remapped at all (unlike .pc, where it's ".").
        XCTAssertEqual(TextConverter.toCyrillic("/", variant: .apple), "/")
        XCTAssertEqual(TextConverter.toCyrillic("/", variant: .pc), ".")
    }
}
```

- [ ] **Step 2: Confirm the test file fails to build (old `TextConverter` signature doesn't take `variant:`)**

Run: `swift test --filter TextConverterTests`
Expected: FAIL to build — `extra argument 'variant' in call` (or similar) at every call site above.

- [ ] **Step 3: Rewrite `Sources/LatCyr/TextConverter.swift`**

```swift
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

    private static func convert(_ text: String, using table: [Character: Character]) -> String {
        String(text.map { char in
            if let mapped = table[char] { return mapped }
            let lower = Character(char.lowercased())
            guard let mapped = table[lower] else { return char }
            return char.isUppercase ? Character(mapped.uppercased()) : mapped
        })
    }
}
```

- [ ] **Step 4: Fix the 3 non-test call sites so the package builds (temporary `.pc` literals)**

In `Sources/LatCyr/LanguageDetector.swift`, replace line 124:
```swift
        guard lower.allSatisfy({ $0.isLetter || TextConverter.ambiguousLetterSymbols.contains($0) }) else { return false }
```
with:
```swift
        guard lower.allSatisfy({ $0.isLetter || TextConverter.ambiguousLetterSymbols(for: .pc).contains($0) }) else { return false }
```

And line 128:
```swift
        let converted = currentLayoutIsRussian ? TextConverter.toLatin(lower) : TextConverter.toCyrillic(lower)
```
with:
```swift
        let converted = currentLayoutIsRussian ? TextConverter.toLatin(lower, variant: .pc) : TextConverter.toCyrillic(lower, variant: .pc)
```

In `Sources/LatCyr/InputMonitor.swift`, replace line 121:
```swift
        if char.isLetter || TextConverter.ambiguousLetterSymbols.contains(char) {
```
with:
```swift
        if char.isLetter || TextConverter.ambiguousLetterSymbols(for: .pc).contains(char) {
```

And line 209:
```swift
        let converted = wasRussian ? TextConverter.toLatin(word) : TextConverter.toCyrillic(word)
```
with:
```swift
        let converted = wasRussian ? TextConverter.toLatin(word, variant: .pc) : TextConverter.toCyrillic(word, variant: .pc)
```

In `Sources/LatCyr/TextFieldController.swift`, replace line 189:
```swift
        if TextConverter.ambiguousLetterSymbols.contains(ch) { return false }
```
with:
```swift
        if TextConverter.ambiguousLetterSymbols(for: .pc).contains(ch) { return false }
```

- [ ] **Step 5: Fix the 3 direct `TextConverter` calls in `Tests/LatCyrTests/LanguageDetectorTests.swift`**

Line 16:
```swift
        XCTAssertEqual(TextConverter.toCyrillic("ndj."), "твою")
```
→
```swift
        XCTAssertEqual(TextConverter.toCyrillic("ndj.", variant: .pc), "твою")
```

Line 63:
```swift
        XCTAssertEqual(TextConverter.toLatin("ыыд"), "ssl")
```
→
```swift
        XCTAssertEqual(TextConverter.toLatin("ыыд", variant: .pc), "ssl")
```

Line 74:
```swift
        XCTAssertEqual(TextConverter.toCyrillic("dep"), "вуз")
```
→
```swift
        XCTAssertEqual(TextConverter.toCyrillic("dep", variant: .pc), "вуз")
```

(`LanguageDetector.isWrongLayout(...)` calls in this file do **not** need touching yet — that function's own signature doesn't gain `variant` until Task 2.)

- [ ] **Step 6: Build and run the full suite**

Run: `swift build && swift test`
Expected: `Build complete!`, all tests pass (20 existing + 9 new `TextConverterTests` = 29 total... actually count precisely from output, don't hardcode; just confirm 0 failures).

- [ ] **Step 7: Commit**

```bash
git add Sources/LatCyr/TextConverter.swift Sources/LatCyr/LanguageDetector.swift Sources/LatCyr/InputMonitor.swift Sources/LatCyr/TextFieldController.swift Tests/LatCyrTests/TextConverterTests.swift Tests/LatCyrTests/LanguageDetectorTests.swift
git commit -m "feat: make TextConverter variant-aware (Russian vs Russian - PC layouts)"
```

---

## Task 2: `LanguageDetector.isWrongLayout` — `variant` parameter

**Files:**
- Modify: `Sources/LatCyr/LanguageDetector.swift:119-142` (function `isWrongLayout`)
- Modify: `Sources/LatCyr/InputMonitor.swift:132` (the one production call site — temporary `.pc` literal, replaced in Task 4)
- Modify: `Tests/LatCyrTests/LanguageDetectorTests.swift` (all existing `isWrongLayout` calls + one new test)

**Interfaces:**
- Consumes: `TextConverter.RussianKeyboardVariant`, `TextConverter.ambiguousLetterSymbols(for:)`, `TextConverter.toLatin(_:variant:)`, `TextConverter.toCyrillic(_:variant:)` (Task 1).
- Produces: `LanguageDetector.isWrongLayout(word: String, currentLayoutIsRussian: Bool, exceptions: Set<String>, variant: TextConverter.RussianKeyboardVariant) -> Bool` — new required parameter, used by Task 4 (`InputMonitor`).

- [ ] **Step 1: Update `Tests/LatCyrTests/LanguageDetectorTests.swift` — add `variant: .pc` to every existing `isWrongLayout` call, add one new test**

Replace the file's content with (unchanged tests get `, variant: .pc` appended; a new test is added at the end, before `testProactiveSwitchToRussian`):

```swift
import XCTest
@testable import LatCyr

final class LanguageDetectorTests: XCTestCase {
    // Russian typed in English layout → detect
    func testRussianTypedInEnglishLayout() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ghbdtn", currentLayoutIsRussian: false, exceptions: [], variant: .pc)) // привет
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "vbh", currentLayoutIsRussian: false, exceptions: [], variant: .pc))     // мир
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ntcn", currentLayoutIsRussian: false, exceptions: [], variant: .pc))    // тест
    }

    // Words containing letters typed via a punctuation key (ё, х, ъ, ж, э,
    // б, ю share a physical key with `, [, ], ;, ', ,, .) must still be
    // detected as a whole, not cut short at the punctuation character.
    func testWordWithAmbiguousPunctuationLetter() {
        XCTAssertEqual(TextConverter.toCyrillic("ndj.", variant: .pc), "твою")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ndj.", currentLayoutIsRussian: false, exceptions: [], variant: .pc)) // твою
    }

    // English typed in Russian layout → detect
    func testEnglishTypedInRussianLayout() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "руддщ", currentLayoutIsRussian: true, exceptions: [], variant: .pc))   // hello
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "цщкду", currentLayoutIsRussian: true, exceptions: [], variant: .pc))   // world
    }

    // Correct words → never touch
    func testCorrectWordsNotTouched() {
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "hello", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "the", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "world", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "привет", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "мир", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "тест", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "следующий", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "здравствуйте", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
    }

    // Short words → never touch
    func testShortWordsNotTouched() {
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "vb", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "gh", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
    }

    // Words with digits → never touch
    func testWordsWithDigitsNotTouched() {
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "ghbdtn123", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "привет1", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
    }

    // Exception words — a Latin exception overrides the score heuristic in
    // both directions. "sdd" typed correctly under the English layout is a
    // real false positive of the plain heuristic (short, consonant-heavy
    // acronyms score ambiguously) — exactly what the whitelist half fixes.
    func testExceptionWordNeverConverted() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "sdd", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "sdd", currentLayoutIsRussian: false, exceptions: ["sdd"], variant: .pc))
    }

    // "ssl" mistyped as "ыыд" under the Russian layout (toLatin("ыыд") ==
    // "ssl"): both scores are too low for the ordinary heuristic to catch
    // it — exactly what the forced-correction half fixes.
    func testExceptionWordAlwaysCorrected() {
        XCTAssertEqual(TextConverter.toLatin("ыыд", variant: .pc), "ssl")
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "ыыд", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ыыд", currentLayoutIsRussian: true, exceptions: ["ssl"], variant: .pc))
    }

    // Same two behaviors, mirrored for a Cyrillic exception word — proves
    // the check isn't hardcoded to Latin-only exceptions.
    func testCyrillicExceptionWordSymmetric() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ффф", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "ффф", currentLayoutIsRussian: true, exceptions: ["ффф"], variant: .pc))

        XCTAssertEqual(TextConverter.toCyrillic("dep", variant: .pc), "вуз")
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "dep", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "dep", currentLayoutIsRussian: false, exceptions: ["вуз"], variant: .pc))
    }

    // The Russian keyboard variant gates which punctuation keys count as
    // letters (LanguageDetector's own guard, not just TextConverter) —
    // "`" is a letter-producing key only under .pc, "\" only under .apple.
    // Hand-verified: englishScore("h`c") ≈ 0.21 (< 0.35), russianScore of
    // its .pc conversion "рёс" ≈ 0.498 (> 0.4), diff ≈ 0.29 (> 0.1) — a
    // genuine wrong-layout hit once the guard admits the backtick.
    func testRussianVariantGatesAmbiguousLetterGuard() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "h`c", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "h`c", currentLayoutIsRussian: false, exceptions: [], variant: .apple))

        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "h\\c", currentLayoutIsRussian: false, exceptions: [], variant: .apple))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "h\\c", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
    }

    // Proactive: English layout → Russian
    func testProactiveSwitchToRussian() {
        XCTAssertTrue(LanguageDetector.proactiveSwitchSignal(first: "j", second: "y", currentLayoutIsRussian: false)) // он
        XCTAssertTrue(LanguageDetector.proactiveSwitchSignal(first: "v", second: "f", currentLayoutIsRussian: false)) // ма
        XCTAssertFalse(LanguageDetector.proactiveSwitchSignal(first: "b", second: "y", currentLayoutIsRussian: false)) // by — excluded
        XCTAssertFalse(LanguageDetector.proactiveSwitchSignal(first: "h", second: "e", currentLayoutIsRussian: false)) // he — not strong
    }

    // Proactive: Russian layout → English
    func testProactiveSwitchToEnglish() {
        XCTAssertTrue(LanguageDetector.proactiveSwitchSignal(first: "ф", second: "ш", currentLayoutIsRussian: true))
        XCTAssertFalse(LanguageDetector.proactiveSwitchSignal(first: "а", second: "п", currentLayoutIsRussian: true))
    }

    // Proactive: leading "/" while Russian is active signals an about-to-be-
    // typed path (terminal-only scope is enforced in InputMonitor, not here).
    func testProactiveSingleCharSwitchToEnglish() {
        XCTAssertTrue(LanguageDetector.proactiveSingleCharSwitchSignal(first: "/", currentLayoutIsRussian: true))
        XCTAssertFalse(LanguageDetector.proactiveSingleCharSwitchSignal(first: "/", currentLayoutIsRussian: false))
        XCTAssertFalse(LanguageDetector.proactiveSingleCharSwitchSignal(first: "a", currentLayoutIsRussian: true))
    }

    // Scores
    func testScores() {
        XCTAssertGreaterThan(LanguageDetector.russianScore("привет"), 0.4)
        XCTAssertLessThan(LanguageDetector.russianScore("руддщ"), 0.4)
        XCTAssertGreaterThan(LanguageDetector.englishScore("hello"), 0.35)
        XCTAssertLessThan(LanguageDetector.englishScore("ghbdtn"), 0.35)
    }
}
```

- [ ] **Step 2: Confirm it fails to build (old `isWrongLayout` signature has no `variant`)**

Run: `swift test --filter LanguageDetectorTests`
Expected: FAIL to build — `missing argument for parameter 'variant' in call`.

- [ ] **Step 3: Update `isWrongLayout` in `Sources/LatCyr/LanguageDetector.swift`**

Replace the function (currently lines 119-142) with:

```swift
    public static func isWrongLayout(
        word: String, currentLayoutIsRussian: Bool, exceptions: Set<String>,
        variant: TextConverter.RussianKeyboardVariant
    ) -> Bool {
        let lower = word.lowercased()
        guard lower.count >= minWordLength else { return false }
        guard lower.allSatisfy({ $0.isLetter || TextConverter.ambiguousLetterSymbols(for: variant).contains($0) }) else { return false }

        if exceptions.contains(lower) { return false }

        let converted = currentLayoutIsRussian ? TextConverter.toLatin(lower, variant: variant) : TextConverter.toCyrillic(lower, variant: variant)
        if exceptions.contains(converted) { return true }

        if currentLayoutIsRussian {
            let russian = russianScore(lower)
            let english = englishScore(converted)
            return english > englishThreshold && russian < russianThreshold
                && english - russian > diffThreshold
        } else {
            let english = englishScore(lower)
            let russian = russianScore(converted)
            return russian > russianThreshold && english < englishThreshold
                && russian - english > diffThreshold
        }
    }
```

(Doc comment kept as-is from the previous revision — still accurate, just gains one more parameter.)

- [ ] **Step 4: Fix the one production call site in `Sources/LatCyr/InputMonitor.swift:132` (temporary `.pc` literal)**

Replace:
```swift
            } else if LanguageDetector.isWrongLayout(word: currentWord, currentLayoutIsRussian: currentLayoutIsRussian, exceptions: exceptionStore.words) {
```
with:
```swift
            } else if LanguageDetector.isWrongLayout(word: currentWord, currentLayoutIsRussian: currentLayoutIsRussian, exceptions: exceptionStore.words, variant: .pc) {
```

- [ ] **Step 5: Build and run the full suite**

Run: `swift build && swift test`
Expected: `Build complete!`, all tests pass, output pristine.

- [ ] **Step 6: Commit**

```bash
git add Sources/LatCyr/LanguageDetector.swift Sources/LatCyr/InputMonitor.swift Tests/LatCyrTests/LanguageDetectorTests.swift
git commit -m "feat: add variant parameter to LanguageDetector.isWrongLayout"
```

---

## Task 3: `LayoutManager` — Byelorussian fix + `currentRussianVariant`

**Files:**
- Modify: `Sources/LatCyr/LayoutManager.swift`

**Interfaces:**
- Consumes: `TextConverter.RussianKeyboardVariant` (Task 1).
- Produces: `LayoutManager.currentRussianVariant: TextConverter.RussianKeyboardVariant` — used by Task 4 (`InputMonitor`).

This task is independent of Task 1/2's `.pc`-literal cleanup — it only adds a new property and tightens an existing check, neither of which any other file currently calls. Safe to do in any order relative to Tasks 1-2, but must land before Task 4.

- [ ] **Step 1: Fix the Byelorussian false-positive and add `currentRussianVariant`**

In `Sources/LatCyr/LayoutManager.swift`, replace:

```swift
    private func layout(of source: TISInputSource) -> Layout {
        guard let id = inputSourceID(source) else { return .other }
        let lower = id.lowercased()
        if lower.contains("russian") { return .russian }
        if lower.contains("us") || lower.contains("abc") || lower.contains("british")
            || lower.contains("english") || lower.contains("australian")
            || lower.contains("canadian") || lower.contains("irish")
            || lower.contains("dvorak") || lower.contains("qwerty") {
            return .english
        }
        return .other
    }
```

with:

```swift
    private func layout(of source: TISInputSource) -> Layout {
        guard let id = inputSourceID(source) else { return .other }
        let lower = id.lowercased()
        // hasPrefix, not contains: "com.apple.keylayout.Byelorussian" also
        // contains the substring "russian" and was previously misdetected
        // as a Russian layout.
        if lower.hasPrefix("com.apple.keylayout.russian") { return .russian }
        if lower.contains("us") || lower.contains("abc") || lower.contains("british")
            || lower.contains("english") || lower.contains("australian")
            || lower.contains("canadian") || lower.contains("irish")
            || lower.contains("dvorak") || lower.contains("qwerty") {
            return .english
        }
        return .other
    }
```

Then add a new computed property, directly after `isRussian` (currently line 20):

```swift
    /// Whether the current layout is Russian.
    var isRussian: Bool { currentLayout == .russian }

    /// Which Russian keyboard variant is active, for TextConverter's
    /// variant-aware conversion. Only "Russian" (Apple's own layout) is
    /// distinguished exactly; every other Russian-family layout ("Russian -
    /// PC", "Russian - QWERTY"/Phonetic, and anything else) falls back to
    /// .pc, matching the mapping this app has always used.
    var currentRussianVariant: TextConverter.RussianKeyboardVariant {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let id = inputSourceID(source) else { return .pc }
        return id == "com.apple.keylayout.Russian" ? .apple : .pc
    }
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!` (no XCTest coverage for this file — thin system wrapper, tested manually per project convention; see Task 6).

- [ ] **Step 3: Commit**

```bash
git add Sources/LatCyr/LayoutManager.swift
git commit -m "fix: stop misdetecting Byelorussian as Russian, add currentRussianVariant"
```

---

## Task 4: `InputMonitor` + `TextFieldController` — thread the real variant through

**Files:**
- Modify: `Sources/LatCyr/InputMonitor.swift`
- Modify: `Sources/LatCyr/TextFieldController.swift`

**Interfaces:**
- Consumes: `LayoutManager.currentRussianVariant` (Task 3), `LanguageDetector.isWrongLayout(...variant:)` (Task 2), `TextConverter.toCyrillic/toLatin(...variant:)` and `ambiguousLetterSymbols(for:)` (Task 1).
- Produces: `TextFieldController.captureWordAnchor(matching:variant:)`, `TextFieldController.replacePrefix(_:with:in:variant:)` — both gain a `variant` parameter (their shared private `isBoundary` needs it). `TextFieldController.replaceAnchoredWord` is **unchanged** — it doesn't call `isBoundary` and doesn't need the parameter (a deliberate refinement from the design doc, which listed all three methods; only two actually touch `isBoundary`).

Combined into one task because `InputMonitor` is `TextFieldController`'s only caller and the two must change together to keep the package building — same reasoning as the earlier `KeystrokeSimulator`+`InputMonitor` merge in the previous plan.

- [ ] **Step 1: `InputMonitor` — add and capture `currentRussianVariant`**

In `Sources/LatCyr/InputMonitor.swift`, replace:

```swift
    // Word buffer state
    private var currentWord = ""
    private var currentLayoutIsRussian = false
```

with:

```swift
    // Word buffer state
    private var currentWord = ""
    private var currentLayoutIsRussian = false
    private var currentRussianVariant: TextConverter.RussianKeyboardVariant = .pc
```

- [ ] **Step 2: `InputMonitor.handle` — read the variant live for the letter-classification check, capture it at word start**

Replace:

```swift
        if char.isLetter || TextConverter.ambiguousLetterSymbols(for: .pc).contains(char) {
            if currentWord.isEmpty {
                currentLayoutIsRussian = layoutManager.isRussian
            }
            currentWord.append(char)
            if currentWord.count == 2 {
                scheduleProactiveCheck()
            }
        } else if isWordBoundary(char) {
            if currentWord.isEmpty {
                scheduleLeadingCharCheck(char)
            } else if LanguageDetector.isWrongLayout(word: currentWord, currentLayoutIsRussian: currentLayoutIsRussian, exceptions: exceptionStore.words, variant: .pc) {
                scheduleRetroactiveCheck(word: currentWord, wasRussian: currentLayoutIsRussian, boundary: char)
            }
            currentWord = ""
        } else {
            currentWord = ""
        }
```

with:

```swift
        // Read live, not from the stored field: on the very first character
        // of a new word this runs before currentRussianVariant is captured
        // below, and using a stale value here (from the *previous* word)
        // could misclassify a genuinely-ambiguous key if the user switched
        // Russian variants between words.
        if char.isLetter || TextConverter.ambiguousLetterSymbols(for: layoutManager.currentRussianVariant).contains(char) {
            if currentWord.isEmpty {
                currentLayoutIsRussian = layoutManager.isRussian
                currentRussianVariant = layoutManager.currentRussianVariant
            }
            currentWord.append(char)
            if currentWord.count == 2 {
                scheduleProactiveCheck()
            }
        } else if isWordBoundary(char) {
            if currentWord.isEmpty {
                scheduleLeadingCharCheck(char)
            } else if LanguageDetector.isWrongLayout(word: currentWord, currentLayoutIsRussian: currentLayoutIsRussian, exceptions: exceptionStore.words, variant: currentRussianVariant) {
                scheduleRetroactiveCheck(word: currentWord, wasRussian: currentLayoutIsRussian, variant: currentRussianVariant, boundary: char)
            }
            currentWord = ""
        } else {
            currentWord = ""
        }
```

- [ ] **Step 3: Thread `variant` through the scheduling and correction methods**

Replace:

```swift
    private func scheduleProactiveCheck() {
        let word = currentWord
        let wasRussian = currentLayoutIsRussian
        DispatchQueue.main.asyncAfter(deadline: .now() + correctionDelay) { [weak self] in
            self?.performProactiveFix(word: word, wasRussian: wasRussian)
        }
    }
```

with:

```swift
    private func scheduleProactiveCheck() {
        let word = currentWord
        let wasRussian = currentLayoutIsRussian
        let variant = currentRussianVariant
        DispatchQueue.main.asyncAfter(deadline: .now() + correctionDelay) { [weak self] in
            self?.performProactiveFix(word: word, wasRussian: wasRussian, variant: variant)
        }
    }
```

Replace:

```swift
    private func scheduleRetroactiveCheck(word: String, wasRussian: Bool, boundary: Character) {
        // Capture the word's position now, synchronously — not 50ms from
        // now, when applyCorrection actually runs. If the user starts the
        // next word without pausing, a cursor-relative lookup done later
        // would find that new word instead of this one and silently fail
        // to correct it (see WordAnchor's doc comment). nil is fine here:
        // it means no AX-correctable target (e.g. a terminal), and the
        // delayed call still runs so the keystroke fallback gets a chance.
        let anchor = textFieldController.captureWordAnchor(matching: word)
        DispatchQueue.main.asyncAfter(deadline: .now() + correctionDelay) { [weak self] in
            self?.applyCorrection(word: word, wasRussian: wasRussian, replacePrefix: false, boundary: boundary, anchor: anchor)
        }
    }
```

with:

```swift
    private func scheduleRetroactiveCheck(word: String, wasRussian: Bool, variant: TextConverter.RussianKeyboardVariant, boundary: Character) {
        // Capture the word's position now, synchronously — not 50ms from
        // now, when applyCorrection actually runs. If the user starts the
        // next word without pausing, a cursor-relative lookup done later
        // would find that new word instead of this one and silently fail
        // to correct it (see WordAnchor's doc comment). nil is fine here:
        // it means no AX-correctable target (e.g. a terminal), and the
        // delayed call still runs so the keystroke fallback gets a chance.
        let anchor = textFieldController.captureWordAnchor(matching: word, variant: variant)
        DispatchQueue.main.asyncAfter(deadline: .now() + correctionDelay) { [weak self] in
            self?.applyCorrection(word: word, wasRussian: wasRussian, variant: variant, replacePrefix: false, boundary: boundary, anchor: anchor)
        }
    }
```

Replace:

```swift
    private func performProactiveFix(word: String, wasRussian: Bool) {
        guard word.count == 2 else { return }
        let chars = Array(word)
        guard LanguageDetector.proactiveSwitchSignal(
            first: chars[0], second: chars[1], currentLayoutIsRussian: wasRussian
        ) else { return }
        // Fast-typing guard: if the buffer has grown past the captured word,
        // bail and let the retroactive path handle the full word.
        guard currentWord == word else { return }
        if applyCorrection(word: word, wasRussian: wasRussian, replacePrefix: true) {
            currentWord = ""
        }
    }
```

with:

```swift
    private func performProactiveFix(word: String, wasRussian: Bool, variant: TextConverter.RussianKeyboardVariant) {
        guard word.count == 2 else { return }
        let chars = Array(word)
        guard LanguageDetector.proactiveSwitchSignal(
            first: chars[0], second: chars[1], currentLayoutIsRussian: wasRussian
        ) else { return }
        // Fast-typing guard: if the buffer has grown past the captured word,
        // bail and let the retroactive path handle the full word.
        guard currentWord == word else { return }
        if applyCorrection(word: word, wasRussian: wasRussian, variant: variant, replacePrefix: true) {
            currentWord = ""
        }
    }
```

- [ ] **Step 4: `applyCorrection` — accept and use `variant`**

Replace:

```swift
    @discardableResult
    private func applyCorrection(
        word: String, wasRussian: Bool, replacePrefix: Bool, boundary: Character? = nil,
        anchor: TextFieldController.WordAnchor? = nil
    ) -> Bool {
        let converted = wasRussian ? TextConverter.toLatin(word, variant: .pc) : TextConverter.toCyrillic(word, variant: .pc)

        let axReplaced: Bool
        if replacePrefix {
            // Proactive path: replacePrefix operates on the word still
            // being typed (no boundary yet). It's re-derived from the live
            // cursor at fire time, same as always — the caller already
            // guards `currentWord == word` before scheduling this, so a
            // fast-typing mismatch bails before we get here.
            if let element = textFieldController.focusedTextElement(),
               !textFieldController.isOwnApp(element),
               !textFieldController.isSecure(element),
               textFieldController.isEditableText(element) {
                axReplaced = textFieldController.replacePrefix(word, with: converted, in: element)
            } else {
                axReplaced = false
            }
        } else if let anchor {
```

with:

```swift
    @discardableResult
    private func applyCorrection(
        word: String, wasRussian: Bool, variant: TextConverter.RussianKeyboardVariant, replacePrefix: Bool,
        boundary: Character? = nil, anchor: TextFieldController.WordAnchor? = nil
    ) -> Bool {
        let converted = wasRussian ? TextConverter.toLatin(word, variant: variant) : TextConverter.toCyrillic(word, variant: variant)

        let axReplaced: Bool
        if replacePrefix {
            // Proactive path: replacePrefix operates on the word still
            // being typed (no boundary yet). It's re-derived from the live
            // cursor at fire time, same as always — the caller already
            // guards `currentWord == word` before scheduling this, so a
            // fast-typing mismatch bails before we get here.
            if let element = textFieldController.focusedTextElement(),
               !textFieldController.isOwnApp(element),
               !textFieldController.isSecure(element),
               textFieldController.isEditableText(element) {
                axReplaced = textFieldController.replacePrefix(word, with: converted, in: element, variant: variant)
            } else {
                axReplaced = false
            }
        } else if let anchor {
```

(The rest of `applyCorrection` — the `replaceAnchoredWord` call, the keystroke-fallback block, `switchLayout` — is unchanged; `replaceAnchoredWord`'s call stays exactly `textFieldController.replaceAnchoredWord(anchor, word: word, with: converted)`, no `variant` argument, per the Interfaces note above.)

- [ ] **Step 5: `TextFieldController` — thread `variant` into `isBoundary`, `captureWordAnchor`, `replacePrefix`**

Replace:

```swift
    func captureWordAnchor(matching word: String) -> WordAnchor? {
        guard let element = focusedTextElement(),
              !isOwnApp(element),
              !isSecure(element),
              isEditableText(element),
              let text = text(of: element),
              let range = selectedRange(of: element) else { return nil }
        let cursor = range.location + range.length
        let utf16 = Array(text.utf16)
        guard cursor >= 0, cursor <= utf16.count else { return nil }

        var end = cursor
        while end > 0 && isBoundary(utf16[end - 1]) { end -= 1 }
        var start = end
        while start > 0 && !isBoundary(utf16[start - 1]) { start -= 1 }
        guard start < end else { return nil }

        let actualWord = String(utf16CodeUnits: Array(utf16[start..<end]), count: end - start)
        guard actualWord.lowercased() == word.lowercased() else { return nil }

        return WordAnchor(element: element, range: start..<end)
    }
```

with:

```swift
    func captureWordAnchor(matching word: String, variant: TextConverter.RussianKeyboardVariant) -> WordAnchor? {
        guard let element = focusedTextElement(),
              !isOwnApp(element),
              !isSecure(element),
              isEditableText(element),
              let text = text(of: element),
              let range = selectedRange(of: element) else { return nil }
        let cursor = range.location + range.length
        let utf16 = Array(text.utf16)
        guard cursor >= 0, cursor <= utf16.count else { return nil }

        var end = cursor
        while end > 0 && isBoundary(utf16[end - 1], variant: variant) { end -= 1 }
        var start = end
        while start > 0 && !isBoundary(utf16[start - 1], variant: variant) { start -= 1 }
        guard start < end else { return nil }

        let actualWord = String(utf16CodeUnits: Array(utf16[start..<end]), count: end - start)
        guard actualWord.lowercased() == word.lowercased() else { return nil }

        return WordAnchor(element: element, range: start..<end)
    }
```

Replace:

```swift
    func replacePrefix(_ prefix: String, with replacement: String, in element: AXUIElement) -> Bool {
        guard let text = text(of: element),
              let range = selectedRange(of: element) else { return false }
        let cursor = range.location + range.length
        let utf16 = Array(text.utf16)
        guard cursor >= 0, cursor <= utf16.count else { return false }

        var start = cursor
        while start > 0 && !isBoundary(utf16[start - 1]) { start -= 1 }
        let prefixEnd = start + prefix.utf16.count
        guard prefixEnd <= utf16.count else { return false }

        let actualPrefix = String(utf16CodeUnits: Array(utf16[start..<prefixEnd]), count: prefix.utf16.count)
        guard actualPrefix.lowercased() == prefix.lowercased() else { return false }

        return replace(range: start..<prefixEnd, with: replacement, in: element, utf16: utf16, cursor: cursor)
    }
```

with:

```swift
    func replacePrefix(_ prefix: String, with replacement: String, in element: AXUIElement, variant: TextConverter.RussianKeyboardVariant) -> Bool {
        guard let text = text(of: element),
              let range = selectedRange(of: element) else { return false }
        let cursor = range.location + range.length
        let utf16 = Array(text.utf16)
        guard cursor >= 0, cursor <= utf16.count else { return false }

        var start = cursor
        while start > 0 && !isBoundary(utf16[start - 1], variant: variant) { start -= 1 }
        let prefixEnd = start + prefix.utf16.count
        guard prefixEnd <= utf16.count else { return false }

        let actualPrefix = String(utf16CodeUnits: Array(utf16[start..<prefixEnd]), count: prefix.utf16.count)
        guard actualPrefix.lowercased() == prefix.lowercased() else { return false }

        return replace(range: start..<prefixEnd, with: replacement, in: element, utf16: utf16, cursor: cursor)
    }
```

Replace:

```swift
    private func isBoundary(_ unit: UInt16) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return true }
        let ch = Character(scalar)
        if TextConverter.ambiguousLetterSymbols(for: .pc).contains(ch) { return false }
        return ch.isWhitespace || ch.isPunctuation || ch.isSymbol || ch.isNewline || ch.isNumber
    }
```

with:

```swift
    private func isBoundary(_ unit: UInt16, variant: TextConverter.RussianKeyboardVariant) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return true }
        let ch = Character(scalar)
        if TextConverter.ambiguousLetterSymbols(for: variant).contains(ch) { return false }
        return ch.isWhitespace || ch.isPunctuation || ch.isSymbol || ch.isNewline || ch.isNumber
    }
```

- [ ] **Step 6: Build and run the full suite**

Run: `swift build && swift test`
Expected: `Build complete!`, all tests pass (this task changes no test-covered logic directly — `InputMonitor`/`TextFieldController` are manually-tested wrappers — this is a regression check).

- [ ] **Step 7: Commit**

```bash
git add Sources/LatCyr/InputMonitor.swift Sources/LatCyr/TextFieldController.swift
git commit -m "feat: thread the captured Russian keyboard variant through InputMonitor and TextFieldController"
```

---

## Task 5: Обновить `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:** нет (документация).

- [ ] **Step 1: Обновить bullet про `LayoutManager.flagsToModifierState` (строка 48)**

Замени:

```markdown
- **`LayoutManager.flagsToModifierState`:** `UCKeyTranslate` ждёт биты `kEventKeyModifier*` (Shift = 0x0002), а не legacy Carbon-биты; эффективный Shift = shift XOR capsLock (на macOS Shift отменяет CapsLock). Смена раскладки ищет первый источник с нужным `inputSourceID` (содержит "russian" / "us", "abc", "british" и т.д.).
```

на:

```markdown
- **`LayoutManager.flagsToModifierState`:** `UCKeyTranslate` ждёт биты `kEventKeyModifier*` (Shift = 0x0002), а не legacy Carbon-биты; эффективный Shift = shift XOR capsLock (на macOS Shift отменяет CapsLock). Смена раскладки ищет первый источник с нужным `inputSourceID` — для русской раскладки строго по префиксу `com.apple.keylayout.russian` (не по вхождению — иначе `Byelorussian` тоже считается русской), для английской — по вхождению "us"/"abc"/"british" и т.д.
```

- [ ] **Step 2: Заменить bullet про `TextConverter.ambiguousLetterSymbols` (строка 51)**

Замени:

```markdown
- **`TextConverter.ambiguousLetterSymbols`** (`` ` `` `,` `.` `;` `'` `[` `]`): физически это буквы (ё, х, ъ, ж, э, б, ю) на клавишах, которые в английской раскладке печатают пунктуацию. Границей слова не считаются — иначе, например, «ю» (клавиша `.`) обрывает буфер до того, как слово попадёт на проверку. `InputMonitor.handle` и `TextFieldController.isBoundary` должны трактовать этот набор одинаково — рассинхрон одного места ломает либо накопление буфера, либо поиск слова в реальном тексте для замены.
```

на:

```markdown
- **`TextConverter.RussianKeyboardVariant` и `ambiguousLetterSymbols(for:)`:** macOS различает как минимум две русские раскладки с разной физической расшифровкой пунктуационных клавиш — «Russian - PC» (`com.apple.keylayout.RussianWin`, `.pc`) и «Russian» (`com.apple.keylayout.Russian`, `.apple`). 26 буквенных клавиш и `[`/`]` совпадают между вариантами; расходятся только `` ` ``/`~`/`\`/`|`/`/`: под `.pc` `` ` ``/`~` → ё/Ё, `/` → `.`; под `.apple` `\`/`|` → ё/Ё, а `` ` `` и `/` не меняются вообще (подтверждено физической проверкой на реальном Mac — см. `docs/superpowers/specs/2026-08-13-russian-keyboard-variant-design.md`). `ambiguousLetterSymbols(for:)` (физически буквы ё, х, ъ, ж, э, б, ю на клавишах пунктуации в английской раскладке) поэтому тоже зависит от варианта — иначе, например, «ю» (клавиша `.`) обрывает буфер до того, как слово попадёт на проверку. `LayoutManager.currentRussianVariant` определяет вариант по точному input source ID (`.apple` только для точного совпадения `com.apple.keylayout.Russian`, всё остальное, включая `Russian-Phonetic`, — `.pc` по умолчанию) и захватывается в `InputMonitor` в тот же момент, что и `currentLayoutIsRussian`, кроме единственной проверки «буква или неоднозначный символ» на первом символе нового слова — она читает `layoutManager.currentRussianVariant` напрямую (свежее значение), а не сохранённое поле, потому что на первом символе поле ещё не обновлено. `InputMonitor.handle`, `TextFieldController.isBoundary` и `LanguageDetector.isWrongLayout` должны получать один и тот же вариант для одного и того же слова — рассинхрон одного места ломает либо накопление буфера, либо поиск слова в реальном тексте для замены, либо саму детекцию.
```

- [ ] **Step 3: Обновить раздел «Тесты» (строка 55)**

Замени:

```markdown
Покрыты только чистые функции: `TextConverterTests` (двусторонняя конвертация, регистр, цифры/символы не трогаются, все 33 буквы, «ё») и `LanguageDetectorTests` (детект «ghbdtn»→привет, «руддщ»→hello, корректные слова не трогаются, короткие слова и слова с цифрами не трогаются, проактивные сигналы, скоры, слова-исключения в обе стороны для латиницы и кириллицы). Системные компоненты (CGEventTap, TIS, AX, файловый I/O `ExceptionStore`/`HybridAppStore`) проверяются вручную: Terminal, Safari, TextEdit, Notes, парольные поля.
```

на:

```markdown
Покрыты только чистые функции: `TextConverterTests` (двусторонняя конвертация для обоих вариантов раскладки — `.pc` и `.apple`, регистр, цифры/символы не трогаются, все 33 буквы, «ё» на своей клавише для каждого варианта, отсутствие «протечки» между вариантами) и `LanguageDetectorTests` (детект «ghbdtn»→привет, «руддщ»→hello, корректные слова не трогаются, короткие слова и слова с цифрами не трогаются, проактивные сигналы, скоры, слова-исключения в обе стороны для латиницы и кириллицы, влияние варианта раскладки на guard неоднозначных символов). Системные компоненты (CGEventTap, TIS, AX, файловый I/O `ExceptionStore`/`HybridAppStore`) проверяются вручную: Terminal, Safari, TextEdit, Notes, парольные поля, обе русские раскладки.
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document RussianKeyboardVariant and the Byelorussian detection fix"
```

---

## Task 6: Ручная сквозная проверка

**Files:** нет (QA, изменений в код нет).

**Interfaces:** нет.

- [ ] **Step 1: Собрать и запустить**

```bash
./scripts/package-app.sh
open dist/LatCyr.app
```

(Выдай Accessibility + Input Monitoring, если ещё не выданы для этого бандла — переупаковка сбрасывает разрешения, см. CLAUDE.md.)

- [ ] **Step 2: Раскладка «Russian» (Apple) — новый исправленный случай**

Переключись на раскладку «Russian» (не «Russian - PC»). В TextEdit, английская раскладка активна де-факто (LatCyr переключит на Русскую после набора неверной раскладки — начни с любой), набери слово, где по ошибке используется физическая клавиша `\` (например, слово с «ё» в середине, набранное по ошибке под английской раскладкой: физически нажатая клавиша `\` при активной английской раскладке печатает `\`). **Ожидаемо:** слово исправляется корректно (использует `\`→ё маппинг, а не старый `` ` ``→ё, которого при раскладке Apple физически не существует).

- [ ] **Step 3: Регресс — «Russian - PC» не сломалась**

Переключись на «Russian - PC» (или используй раскладку, с которой это исторически тестировалось). Набери слово с ошибкой раскладки, содержащее «ё» (например «ещё» по ошибке в английской раскладке — физическая клавиша `` ` ``). **Ожидаемо:** поведение идентично тому, что было до этой задачи.

- [ ] **Step 4: Byelorussian (если раскладка установлена — опционально)**

Если у тебя установлена белорусская раскладка ввода, переключись на неё и набери что угодно. **Ожидаемо:** LatCyr не пытается её корректировать как русскую (раньше — пыталась).

- [ ] **Step 5: Полный прогон тестов**

```bash
swift test
```

Expected: все тесты (`TextConverterTests`, `LanguageDetectorTests`) зелёные.
