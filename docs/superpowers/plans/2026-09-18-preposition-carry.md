# Подхват коротких служебных слов при коррекции — План реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Предлог, набранный в неправильной раскладке, исправляется вместе со следующим за ним словом: `d ujhjl` → «в город», `b d ujhjlt` → «и в городе».

**Architecture:** Недостающий сигнал берётся из контекста, а не из самого слова. `InputMonitor` копит цепочку неисправленных коротких слов в новом чистом типе `CarryBuffer`; попасть туда может только слово, чью конверсию `LanguageDetector.isCarriableFunctionWord` нашёл в курируемом списке служебных слов целевого языка. Когда следующее слово опознано как неправильная раскладка, цепочка и слово склеиваются в один span и заменяются **одной** правкой — через расширенный назад `WordAnchor` на AX-пути или через удлинённую арифметику keystroke-fallback'а в терминале.

**Tech Stack:** Swift Package (без Xcode), XCTest, Accessibility API, CoreGraphics `CGEventTap`.

**Спецификация:** `docs/superpowers/specs/2026-09-18-preposition-carry-design.md`

## Global Constraints

- Все комментарии в коде — на английском (текущий стиль репозитория).
- `LanguageDetector`, `TextConverter` и новый `CarryBuffer` остаются чистыми: никаких системных API, никакого файлового I/O.
- Пороги эвристики не трогаются: `russianThreshold = 0.4`, `englishThreshold = 0.35`, `diffThreshold = 0.1`, `minWordLength = 3`, `runPenalty = 0.15`.
- Публичная сигнатура `LanguageDetector.isWrongLayout(word:currentLayoutIsRussian:exceptions:variant:)` не меняется; её поведение не меняется ни на одном существующем кейсе.
- Порядок в `applyCorrection` — «замена текста → переключение раскладки» — не меняется.
- Режим event tap не меняется: `options: .defaultTap`, `place: .headInsertEventTap`.
- Синтетические события помечаются `KeystrokeSimulator.eventMarker`; новых мест инъекции не добавляется.
- Подхват строго аддитивен: любой сбой проверки откатывает поведение к сегодняшнему (исправляется одно текущее слово), но никогда не отменяет коррекцию целиком.
- Разделитель между звеньями цепочки — ровно один пробел `" "`, ничего другого.
- Коммиты — conventional style (`feat:`, `fix:`, `docs:`).

## Структура файлов

| Файл | Ответственность |
|---|---|
| `Sources/LatCyr/LanguageDetector.swift` | **Изменяется.** Добавляется критерий переноса и два списка служебных слов. Остаётся чистым. |
| `Sources/LatCyr/CarryBuffer.swift` | **Создаётся.** Накопление цепочки и её валидность по раскладке/варианту. Чистый value type. |
| `Sources/LatCyr/TextFieldController.swift` | **Изменяется.** Расширение якоря назад по span'у; `replacePrefix` учится переносу. |
| `Sources/LatCyr/InputMonitor.swift` | **Изменяется.** Точки накопления и сброса цепочки, склейка span'а, разрешение переноса. |
| `Tests/LatCyrTests/LanguageDetectorTests.swift` | **Изменяется.** Тесты критерия переноса. |
| `Tests/LatCyrTests/CarryBufferTests.swift` | **Создаётся.** Тесты накопления и сброса. |
| `CLAUDE.md` | **Изменяется.** Новый пункт в «Ключевые решения, которые легко сломать» + строка про тесты. |

---

## Task 1: Критерий переноса и списки служебных слов

**Files:**
- Modify: `Sources/LatCyr/LanguageDetector.swift` (добавление в конец `enum`, перед закрывающей скобкой)
- Test: `Tests/LatCyrTests/LanguageDetectorTests.swift`

**Interfaces:**
- Consumes: `TextConverter.toLatin(_:variant:)`, `TextConverter.toCyrillic(_:variant:)`, `TextConverter.ambiguousLetterSymbols(for:)`.
- Produces: `LanguageDetector.isCarriableFunctionWord(word:currentLayoutIsRussian:exceptions:variant:) -> Bool` — публичная статическая чистая функция. Списки `russianFunctionWords` / `englishFunctionWords` — приватные.

- [ ] **Step 1: Написать падающие тесты**

Добавить в `Tests/LatCyrTests/LanguageDetectorTests.swift` перед закрывающей скобкой класса:

```swift
    // A short function word is never corrected on its own — "d" is one
    // character, far below minWordLength — but must be recognised as
    // carriable, so the word that follows can take it along.
    func testCarriableFunctionWordBothDirections() {
        XCTAssertEqual(TextConverter.toCyrillic("d", variant: .pc), "в")
        XCTAssertTrue(LanguageDetector.isCarriableFunctionWord(word: "d", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
        XCTAssertTrue(LanguageDetector.isCarriableFunctionWord(word: "yf", currentLayoutIsRussian: false, exceptions: [], variant: .pc))  // на
        XCTAssertTrue(LanguageDetector.isCarriableFunctionWord(word: "yfl", currentLayoutIsRussian: false, exceptions: [], variant: .pc)) // над
        XCTAssertTrue(LanguageDetector.isCarriableFunctionWord(word: "D", currentLayoutIsRussian: false, exceptions: [], variant: .pc))   // case-insensitive

        XCTAssertEqual(TextConverter.toLatin("шт", variant: .pc), "in")
        XCTAssertTrue(LanguageDetector.isCarriableFunctionWord(word: "шт", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertEqual(TextConverter.toLatin("еру", variant: .pc), "the")
        XCTAssertTrue(LanguageDetector.isCarriableFunctionWord(word: "еру", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
    }

    // Anything that isn't in the curated list stays out, however short.
    func testNonFunctionWordNotCarriable() {
        XCTAssertFalse(LanguageDetector.isCarriableFunctionWord(word: "ujhjl", currentLayoutIsRussian: false, exceptions: [], variant: .pc)) // город
        XCTAssertFalse(LanguageDetector.isCarriableFunctionWord(word: "abc", currentLayoutIsRussian: false, exceptions: [], variant: .pc))   // фис
        XCTAssertFalse(LanguageDetector.isCarriableFunctionWord(word: "hello", currentLayoutIsRussian: false, exceptions: [], variant: .pc)) // рудды
        XCTAssertFalse(LanguageDetector.isCarriableFunctionWord(word: "d1", currentLayoutIsRussian: false, exceptions: [], variant: .pc))    // digit
        XCTAssertFalse(LanguageDetector.isCarriableFunctionWord(word: "", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
    }

    // "об" is typed as "j," — the comma is a letter key under the Russian
    // layout, so the same ambiguous-symbol guard as isWrongLayout is needed
    // or the word fails the "letters only" check.
    func testCarriableWordWithAmbiguousSymbol() {
        XCTAssertEqual(TextConverter.toCyrillic("j,", variant: .pc), "об")
        XCTAssertTrue(LanguageDetector.isCarriableFunctionWord(word: "j,", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
    }

    // A user exception beats the list, exactly as it beats the score
    // heuristic in isWrongLayout.
    func testExceptionOverridesCarry() {
        XCTAssertFalse(LanguageDetector.isCarriableFunctionWord(word: "d", currentLayoutIsRussian: false, exceptions: ["d"], variant: .pc))
    }

    // The direction that could bite: a legitimate one-letter Russian word
    // standing before English text. "и цщкду" is "и world" — "и" converts to
    // "b", which is not an English function word, so it is left alone. The
    // list being per-target-language is what makes this free.
    func testLegitimateRussianWordBeforeEnglishNotCarried() {
        XCTAssertEqual(TextConverter.toLatin("и", variant: .pc), "b")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "цщкду", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isCarriableFunctionWord(word: "и", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
    }
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --filter LanguageDetectorTests`
Expected: FAIL на этапе компиляции — `type 'LanguageDetector' has no member 'isCarriableFunctionWord'`.

- [ ] **Step 3: Реализовать критерий**

Добавить в `Sources/LatCyr/LanguageDetector.swift` перед закрывающей скобкой `enum LanguageDetector`:

```swift
    // MARK: - Carried function words

    /// Short function words — prepositions, conjunctions, particles and the
    /// most common short pronouns — recognised as the *conversion* of a word
    /// that is to be corrected together with the wrong-layout word after it.
    ///
    /// Curated rather than derived, for the same reason as knownTLDs: there
    /// is no heuristic left to lean on. A one- or two-letter word carries no
    /// frequency signal, so a score over it is noise, and lowering
    /// minWordLength or englishThreshold to admit such words would start
    /// converting real short English ones ("the", "and", "cd", "npm").
    ///
    /// Several of the Latin keystrokes that produce an entry here are real
    /// English tokens in their own right: "c" (с), "r" (к), "e" (у), "bp"
    /// (из), "kb" (ли), "vs" (мы), "ds" (вы), "ns" (ты). That is precisely
    /// why this list is never consulted on its own — isCarriableFunctionWord
    /// is only ever reached once the *following* word has been confirmed
    /// wrong-layout, and "vs ujhjl" is not a sequence real English text
    /// produces.
    ///
    /// When adding a word, check it the way a TLD is checked: convert it to
    /// the other layout and ask whether the result appears in real text as a
    /// standalone token directly before a word of the other language.
    private static let russianFunctionWords: Set<String> = [
        "в", "во", "и", "а", "но", "да", "к", "ко", "с", "со", "о", "об",
        "у", "за", "на", "по", "до", "из", "от", "для", "над", "под",
        "при", "про", "без", "не", "ни", "то", "так", "как", "что",
        "же", "ли", "бы", "вот", "я", "мы", "вы", "ты", "он", "мне",
    ]

    /// The English half. Keeping the rule per-target-language is what makes
    /// the Russian→English direction safe for free: "и цщкду" ("и world")
    /// converts "и" to "b", and "b" is not an English function word, so a
    /// genuine one-letter Russian word standing before English text is
    /// never swept up.
    private static let englishFunctionWords: Set<String> = [
        "a", "i", "an", "the", "in", "on", "at", "to", "of", "is", "it",
        "be", "or", "and", "but", "not", "no", "so", "we", "he", "my",
        "do", "if", "as", "up", "us", "me", "by", "for",
    ]

    /// Whether `word`, left uncorrected on its own, should be corrected
    /// together with the wrong-layout word that follows it.
    ///
    /// Deliberately has no score component — see russianFunctionWords. The
    /// signal the word itself cannot supply comes from the caller's context
    /// instead, and the list bounds what that context is allowed to sweep up.
    public static func isCarriableFunctionWord(
        word: String, currentLayoutIsRussian: Bool, exceptions: Set<String>,
        variant: TextConverter.RussianKeyboardVariant
    ) -> Bool {
        let lower = word.lowercased()
        guard !lower.isEmpty else { return false }
        // Same guard as isWrongLayout: "об" is typed as "j,", and the comma
        // is a letter key under the Russian layout.
        guard lower.allSatisfy({ $0.isLetter || TextConverter.ambiguousLetterSymbols(for: variant).contains($0) }) else { return false }
        if exceptions.contains(lower) { return false }

        let converted = currentLayoutIsRussian
            ? TextConverter.toLatin(lower, variant: variant)
            : TextConverter.toCyrillic(lower, variant: variant)
        return currentLayoutIsRussian
            ? englishFunctionWords.contains(converted)
            : russianFunctionWords.contains(converted)
    }
```

- [ ] **Step 4: Запустить тесты и убедиться, что они проходят**

Run: `swift test --filter LanguageDetectorTests`
Expected: PASS, все тесты класса — и новые, и существующие (существующие подтверждают, что `isWrongLayout` не задет).

- [ ] **Step 5: Коммит**

```bash
git add Sources/LatCyr/LanguageDetector.swift Tests/LatCyrTests/LanguageDetectorTests.swift
git commit -m "feat: recognise short function words as carriable into a correction"
```

---

## Task 2: `CarryBuffer` — накопление цепочки

**Files:**
- Create: `Sources/LatCyr/CarryBuffer.swift`
- Test: `Tests/LatCyrTests/CarryBufferTests.swift` (создаётся)

**Interfaces:**
- Consumes: `TextConverter.RussianKeyboardVariant` (`Equatable`).
- Produces: `struct CarryBuffer` (internal), со статической `maxWords: Int = 3`, мутирующими `append(_:layoutIsRussian:variant:)` и `reset()`, и читающей `carried(layoutIsRussian:variant:) -> [String]`.

- [ ] **Step 1: Написать падающие тесты**

Создать `Tests/LatCyrTests/CarryBufferTests.swift`:

```swift
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
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --filter CarryBufferTests`
Expected: FAIL на этапе компиляции — `cannot find 'CarryBuffer' in scope`.

- [ ] **Step 3: Реализовать `CarryBuffer`**

Создать `Sources/LatCyr/CarryBuffer.swift`:

```swift
import Foundation

/// Short function words seen since the last reset, waiting to be corrected
/// together with the next word that turns out to be wrong-layout.
///
/// A pure value type on purpose: *what* may be carried is LanguageDetector's
/// decision, *whether the chain is still valid* is this type's, and neither
/// touches a system API — so both stay unit-tested, unlike the AX and event
/// tap wrappers that use them.
struct CarryBuffer {
    /// Ceiling on the chain length. It bounds how many characters the
    /// terminal keystroke fallback deletes blind: that path has no readback
    /// to verify against, so an unbounded chain would grow unverified
    /// deletion without limit.
    static let maxWords = 3

    private var words: [String] = []
    private var layoutIsRussian = false
    private var variant: TextConverter.RussianKeyboardVariant = .pc

    /// Append a word to the chain. A word typed under a different layout or
    /// Russian variant starts a fresh chain instead of extending the old
    /// one: the user may have switched by hand between the two words, and
    /// then the earlier links describe text in the other layout.
    mutating func append(
        _ word: String, layoutIsRussian: Bool,
        variant: TextConverter.RussianKeyboardVariant
    ) {
        if !words.isEmpty, layoutIsRussian != self.layoutIsRussian || variant != self.variant {
            words.removeAll()
        }
        self.layoutIsRussian = layoutIsRussian
        self.variant = variant
        words.append(word)
        // Drop from the front, never the back: the chain has to stay
        // contiguous with the word that follows it.
        if words.count > Self.maxWords {
            words.removeFirst(words.count - Self.maxWords)
        }
    }

    mutating func reset() {
        words.removeAll()
    }

    /// The chain in typing order, or nothing when it belongs to a different
    /// layout or Russian variant than the correction about to be applied.
    func carried(
        layoutIsRussian: Bool, variant: TextConverter.RussianKeyboardVariant
    ) -> [String] {
        guard layoutIsRussian == self.layoutIsRussian, variant == self.variant else { return [] }
        return words
    }
}
```

- [ ] **Step 4: Запустить тесты и убедиться, что они проходят**

Run: `swift test --filter CarryBufferTests`
Expected: PASS, 6 тестов.

- [ ] **Step 5: Коммит**

```bash
git add Sources/LatCyr/CarryBuffer.swift Tests/LatCyrTests/CarryBufferTests.swift
git commit -m "feat: add CarryBuffer for the chain of pending function words"
```

---

## Task 3: Расширение диапазона замены назад (AX)

**Files:**
- Modify: `Sources/LatCyr/TextFieldController.swift` (новый публичный `extendAnchor`, новый приватный `extendRange`, новый параметр у `replacePrefix`)

**Interfaces:**
- Consumes: `WordAnchor` (существующий), приватные `text(of:)`, `selectedRange(of:)`, `replace(range:with:in:utf16:cursor:)`, `isBoundary(_:variant:)`.
- Produces:
  - `TextFieldController.extendAnchor(_ anchor: WordAnchor, backwardOver words: [String]) -> WordAnchor?`
  - `TextFieldController.replacePrefix(_ prefix: String, carrying carried: [String], with replacement: String, in element: AXUIElement, variant: TextConverter.RussianKeyboardVariant) -> Bool` — параметр `carrying` имеет значение по умолчанию `[]`, поэтому существующие вызовы компилируются без правок.

Системный код (AX), юнит-тестами не покрывается — проверяется вручную в Task 5.

- [ ] **Step 1: Добавить `extendAnchor` и приватный `extendRange`**

В `Sources/LatCyr/TextFieldController.swift` добавить сразу после метода `replaceAnchoredWord`:

```swift
    /// Widen `anchor` backwards over `words` — the chain of short function
    /// words typed immediately before the anchored one — so the whole span
    /// can be replaced in a single edit.
    ///
    /// One edit rather than two is not a stylistic preference: two edits
    /// would have the second computing its offsets against a snapshot the
    /// first had already invalidated.
    ///
    /// Returns nil when the live text doesn't match — the caller then
    /// corrects the anchored word alone, exactly as it did before carrying
    /// existed. That fallback is what keeps the feature strictly additive.
    func extendAnchor(_ anchor: WordAnchor, backwardOver words: [String]) -> WordAnchor? {
        guard !words.isEmpty, let text = text(of: anchor.element) else { return nil }
        let utf16 = Array(text.utf16)
        guard anchor.range.upperBound <= utf16.count,
              let start = extendRange(anchor.range, backwardOver: words, in: utf16) else { return nil }
        return WordAnchor(element: anchor.element, range: start..<anchor.range.upperBound)
    }
```

И в секцию `// MARK: - Private`, рядом с `replace(range:...)`:

```swift
    /// UTF-16 code unit for the space character. The only separator a chain
    /// is allowed to span: it is identical in both layouts, so converting
    /// the joined span never has to decide anything about separators.
    private static let spaceUTF16: UInt16 = 32

    /// The lower bound `range` reaches when widened backwards over `words`,
    /// each preceded by exactly one space, or nil if the text doesn't match.
    private func extendRange(_ range: Range<Int>, backwardOver words: [String], in utf16: [UInt16]) -> Int? {
        var start = range.lowerBound
        for word in words.reversed() {
            guard start > 0, utf16[start - 1] == Self.spaceUTF16 else { return nil }
            start -= 1
            let length = word.utf16.count
            guard length > 0, start >= length else { return nil }
            let candidate = String(utf16CodeUnits: Array(utf16[(start - length)..<start]), count: length)
            guard candidate.lowercased() == word.lowercased() else { return nil }
            start -= length
        }
        return start
    }
```

- [ ] **Step 2: Научить `replacePrefix` переносу**

Заменить существующий `replacePrefix` в `Sources/LatCyr/TextFieldController.swift` целиком на:

```swift
    /// Replace the first `prefix.count` characters of the current word with
    /// `replacement` (used by the proactive path). When `carried` is
    /// non-empty, `replacement` is the conversion of the whole span
    /// (carried words + prefix, single-space separated) and the replaced
    /// range starts at the first carried word instead of at the prefix.
    func replacePrefix(
        _ prefix: String, carrying carried: [String] = [], with replacement: String,
        in element: AXUIElement, variant: TextConverter.RussianKeyboardVariant
    ) -> Bool {
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

        var spanStart = start
        if !carried.isEmpty {
            guard let widened = extendRange(start..<prefixEnd, backwardOver: carried, in: utf16) else { return false }
            spanStart = widened
        }
        return replace(range: spanStart..<prefixEnd, with: replacement, in: element, utf16: utf16, cursor: cursor)
    }
```

- [ ] **Step 3: Проверить, что проект собирается и существующие тесты зелёные**

Run: `swift build && swift test`
Expected: сборка без ошибок и предупреждений; все существующие тесты проходят (`replacePrefix` вызывается в `InputMonitor` без нового аргумента — работает значение по умолчанию).

- [ ] **Step 4: Коммит**

```bash
git add Sources/LatCyr/TextFieldController.swift
git commit -m "feat: widen an anchor backwards over carried words"
```

---

## Task 4: Ретроактивный путь — накопление, сброс, замена span'а

**Files:**
- Modify: `Sources/LatCyr/InputMonitor.swift`

**Interfaces:**
- Consumes: `CarryBuffer` (Task 2), `LanguageDetector.isCarriableFunctionWord(...)` (Task 1), `TextFieldController.extendAnchor(_:backwardOver:)` (Task 3).
- Produces: приватный `resolveCarry(_:anchor:) -> (anchor: TextFieldController.WordAnchor?, carried: [String])`. Сигнатуры `applyCorrection`, `applyCorrectionNow` и `scheduleRetroactiveCheck` получают параметр `carried: [String]`.

Системный код (event tap + AX), юнит-тестами не покрывается — проверяется вручную в Task 5.

- [ ] **Step 1: Добавить поле буфера**

В `Sources/LatCyr/InputMonitor.swift`, в блоке `// Word buffer state`, после `private var currentRussianVariant`:

```swift
    /// Short function words typed just before the current one, eligible to
    /// be corrected along with it. See CarryBuffer and the CLAUDE.md entry
    /// on why the criterion is contextual rather than score-based.
    private var carry = CarryBuffer()
```

- [ ] **Step 2: Сбрасывать цепочку везде, где сбрасывается контекст**

Четыре точечные правки в том же файле.

В обработчике `NSWorkspace.didActivateApplicationNotification` внутри `start()`:

```swift
        ) { [weak self] _ in
            self?.currentWord = ""
            self?.carry.reset()
        }
```

В `stop()`, после `currentWord = ""`:

```swift
        carry.reset()
```

Ветка Backspace в `handle()` — заменить целиком:

```swift
        // Backspace (kVK_Delete = 51): shrink the word buffer.
        if keyCode == 51 {
            if currentWord.isEmpty {
                // Deleting past the start of the word eats the separator or
                // the carried word itself, so the chain no longer describes
                // the text in front of the cursor.
                carry.reset()
            } else {
                currentWord.removeLast()
            }
            return false
        }
```

Ветка «клавиша не даёт символа» (стрелки, функциональные клавиши) — заменить целиком:

```swift
        guard let char = layoutManager.character(forKeyCode: keyCode, flags: flags) else {
            currentWord = ""
            // An arrow key moves the cursor away from the chain; anything
            // else here is just as opaque. Either way the chain can no
            // longer be assumed to sit right before the cursor.
            carry.reset()
            return false
        }
```

- [ ] **Step 3: Переписать ветку границы слова**

В `handle()` заменить блок `} else if isWordBoundary(char) { ... } else { currentWord = "" }` целиком на:

```swift
        } else if isWordBoundary(char) {
            if currentWord.isEmpty {
                // A boundary with nothing buffered is a second separator
                // (double space, ", "). A chain is only ever carried across
                // exactly one space, so this one is spent.
                carry.reset()
                scheduleLeadingCharCheck(char)
            } else if LanguageDetector.isWrongLayout(word: currentWord, currentLayoutIsRussian: currentLayoutIsRussian, exceptions: exceptionStore.words, variant: currentRussianVariant) {
                let carried = carry.carried(layoutIsRussian: currentLayoutIsRussian, variant: currentRussianVariant)
                carry.reset()
                if char.isNewline || char == "\t" {
                    let word = currentWord
                    currentWord = ""
                    return applyCorrectionNow(
                        word: word, carried: carried, wasRussian: currentLayoutIsRussian,
                        variant: currentRussianVariant, keyCode: keyCode
                    )
                }
                scheduleRetroactiveCheck(word: currentWord, carried: carried, wasRussian: currentLayoutIsRussian, variant: currentRussianVariant, boundary: char)
            } else if char == " ", LanguageDetector.isCarriableFunctionWord(
                word: currentWord, currentLayoutIsRussian: currentLayoutIsRussian,
                exceptions: exceptionStore.words, variant: currentRussianVariant
            ) {
                // Not correctable on its own — too short for the heuristic to
                // judge — but a known function word, so the next word gets a
                // chance to take it along.
                carry.append(currentWord, layoutIsRussian: currentLayoutIsRussian, variant: currentRussianVariant)
            } else {
                carry.reset()
            }
            currentWord = ""
        } else {
            currentWord = ""
            carry.reset()
        }
```

- [ ] **Step 4: Разрешать перенос синхронно, на границе**

Заменить `scheduleRetroactiveCheck` целиком и добавить после него `resolveCarry`:

```swift
    private func scheduleRetroactiveCheck(word: String, carried: [String], wasRussian: Bool, variant: TextConverter.RussianKeyboardVariant, boundary: Character) {
        // Capture the word's position now, synchronously — not 50ms from
        // now, when applyCorrection actually runs. If the user starts the
        // next word without pausing, a cursor-relative lookup done later
        // would find that new word instead of this one and silently fail
        // to correct it (see WordAnchor's doc comment). nil is fine here:
        // it means no AX-correctable target (e.g. a terminal), and the
        // delayed call still runs so the keystroke fallback gets a chance.
        let captured = textFieldController.captureWordAnchor(matching: word, variant: variant)
        let resolved = resolveCarry(carried, anchor: captured)
        DispatchQueue.main.asyncAfter(deadline: .now() + correctionDelay) { [weak self] in
            self?.applyCorrection(word: word, carried: resolved.carried, wasRussian: wasRussian, variant: variant, replacePrefix: false, boundary: boundary, anchor: resolved.anchor)
        }
    }

    /// Check the carried chain against the live text and either widen the
    /// anchor to cover it or drop it — synchronously, at the boundary, for
    /// the same reason the anchor itself is captured there: 50ms later the
    /// question would be asked about text the user has since typed.
    ///
    /// A nil anchor is not a rejection. It means there is no AX target at
    /// all (a terminal), so there is nothing to widen and nothing to verify
    /// against — the chain is handed to the keystroke fallback on exactly
    /// the same trust as the word itself already is.
    private func resolveCarry(
        _ carried: [String], anchor: TextFieldController.WordAnchor?
    ) -> (anchor: TextFieldController.WordAnchor?, carried: [String]) {
        guard let anchor, !carried.isEmpty else { return (anchor, carried) }
        guard let widened = textFieldController.extendAnchor(anchor, backwardOver: carried) else {
            return (anchor, [])
        }
        return (widened, carried)
    }
```

- [ ] **Step 5: Провести `carried` через `applyCorrectionNow`**

Заменить сигнатуру и тело `applyCorrectionNow` (док-комментарий над ним не трогать):

```swift
    private func applyCorrectionNow(
        word: String, carried: [String], wasRussian: Bool,
        variant: TextConverter.RussianKeyboardVariant, keyCode: CGKeyCode
    ) -> Bool {
        let captured = textFieldController.captureWordAnchor(matching: word, variant: variant)
        let resolved = resolveCarry(carried, anchor: captured)
        guard applyCorrection(
            word: word, carried: resolved.carried, wasRussian: wasRussian, variant: variant,
            replacePrefix: false, boundary: nil, anchor: resolved.anchor
        ) else { return false }
        return keystrokeSimulator.replay(keyCode: keyCode)
    }
```

- [ ] **Step 6: Склеивать span в `applyCorrection`**

В `applyCorrection` заменить сигнатуру и первые строки:

```swift
    @discardableResult
    private func applyCorrection(
        word: String, carried: [String] = [], wasRussian: Bool, variant: TextConverter.RussianKeyboardVariant, replacePrefix: Bool,
        boundary: Character? = nil, anchor: TextFieldController.WordAnchor? = nil
    ) -> Bool {
        // One span, one conversion: TextConverter leaves unmapped characters
        // alone and the space key is in neither table, so joining the chain
        // and converting the result handles the separators for free.
        let span = (carried + [word]).joined(separator: " ")
        let converted = wasRussian ? TextConverter.toLatin(span, variant: variant) : TextConverter.toCyrillic(span, variant: variant)
```

Внутри ветки `if replacePrefix`, заменить вызов:

```swift
                axReplaced = textFieldController.replacePrefix(word, carrying: carried, with: converted, in: element, variant: variant)
```

Внутри ветки `} else if let anchor {`, заменить вызов:

```swift
            axReplaced = textFieldController.replaceAnchoredWord(anchor, word: span, with: converted)
```

В блоке keystroke-fallback заменить обе арифметики на span:

```swift
            deleteCount = span.count + 1
            typed = converted + String(boundary)
        } else {
            deleteCount = span.count
            typed = converted
        }
```

- [ ] **Step 7: Собрать и прогнать тесты**

Run: `swift build && swift test`
Expected: сборка без ошибок; все тесты (`TextConverterTests`, `LanguageDetectorTests`, `ExceptionWordTests`, `CarryBufferTests`) проходят.

- [ ] **Step 8: Коммит**

```bash
git add Sources/LatCyr/InputMonitor.swift
git commit -m "fix: correct short function words together with the word after them"
```

---

## Task 5: Проактивный путь, документация и ручная проверка

**Files:**
- Modify: `Sources/LatCyr/InputMonitor.swift` (`performProactiveFix`, `performLeadingCharCheck`)
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: `resolveCarry(_:anchor:)` и `applyCorrection(word:carried:...)` из Task 4, `TextFieldController.captureWordAnchor(matching:variant:)`.
- Produces: ничего нового наружу.

- [ ] **Step 1: Подхватывать цепочку на проактивном пути**

В `Sources/LatCyr/InputMonitor.swift` заменить `performProactiveFix` целиком:

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
        // Verify the chain before editing rather than retrying afterwards: a
        // failed edit may already have injected keystrokes in a terminal, and
        // a second attempt would inject them twice. captureWordAnchor works
        // here even mid-word — the cursor sits right after the two typed
        // characters, so it finds exactly this word.
        let pending = carry.carried(layoutIsRussian: wasRussian, variant: variant)
        let carried = pending.isEmpty
            ? []
            : resolveCarry(pending, anchor: textFieldController.captureWordAnchor(matching: word, variant: variant)).carried
        if applyCorrection(word: word, carried: carried, wasRussian: wasRussian, variant: variant, replacePrefix: true) {
            currentWord = ""
            carry.reset()
        }
    }
```

Без этого остаётся дыра, которую ретроактивный путь не закроет никогда: в `d yfxfkt` («в начале») `yf` — сильный сигнал, проактивный путь срабатывает на 2-м символе и переключает раскладку, остаток слова набирается уже правильно, и `isWrongLayout` не вызовется.

- [ ] **Step 2: Сбрасывать цепочку в `performLeadingCharCheck`**

В том же файле, в `performLeadingCharCheck`, после `switchLayout(wasRussian: wasRussian)` заменить хвост:

```swift
        // Drop whatever's accumulated since — it started under the layout
        // we just left, and letting it mix with post-switch typing would
        // feed a stale currentLayoutIsRussian into a later correction.
        currentWord = ""
        carry.reset()
```

- [ ] **Step 3: Собрать и прогнать тесты**

Run: `swift build && swift test`
Expected: сборка без ошибок; все тесты проходят.

- [ ] **Step 4: Задокументировать решение в `CLAUDE.md`**

В разделе «Ключевые решения, которые легко сломать» добавить новым пунктом, после пункта про `performLeadingCharCheck`:

```markdown
- **Подхват коротких служебных слов (`CarryBuffer`) опирается на контекст, а не на скоринг:** предлог из 1–2 букв не проходит `minWordLength`, а трёхбуквенный проходит не всегда (`yfl` → «над» даёт `englishScore` 0.439 при пороге 0.35, потому что `y` — английская гласная и доля гласных у `yfl` идеальна для английского слова). К моменту коррекции следующего слова предлог и потерян из буфера, и неоценим в одиночку: усреднять частоту по одной букве нечего. Понижать пороги нельзя — посыплются «the», «and», «cd», «npm». Поэтому `InputMonitor` копит цепочку неисправленных слов в `CarryBuffer`, а `LanguageDetector.isCarriableFunctionWord` пропускает в неё только те, чья конверсия есть в курируемом списке служебных слов **целевого** языка (`russianFunctionWords`/`englishFunctionWords`). Критерий **никогда не применяется сам по себе** — только после того, как следующее слово уже уверенно опознано `isWrongLayout`: часть латинских наборов (`c`→с, `r`→к, `e`→у, `bp`→из, `kb`→ли, `vs`→мы, `ds`→вы, `ns`→ты) — реальные английские токены, и без контекста список был бы опаснее любой эвристики. Симметрия списков бесплатно закрывает обратное направление: «и» перед английским текстом конвертируется в `b`, а `b` не английское служебное слово, так что настоящее русское однобуквенное слово не трогается. Цепочка рвётся всем, что нарушает «ровно один пробел между звеньями»: не-пробельной границей, вторым пробелом (приходит с пустым буфером), Backspace на пустом буфере, клавишей без символа (стрелки), сменой раскладки или русского варианта, переключением приложения, применённой коррекцией. Замена делается **одной** правкой span'а (`(carried + [word]).joined(separator: " ")`, конвертируется целиком — пробела нет ни в одной таблице `TextConverter`): две правки считали бы смещения по снимку, который первая уже сделала недействительным. Решение «расширять якорь или нет» принимается синхронно на границе, рядом с `captureWordAnchor` (`resolveCarry`), и при неудаче откатывается к одному слову — подхват не может сделать хуже, чем было. Отсутствующий якорь при этом не отказ, а терминал: сверять не с чем, цепочка уходит в keystroke-fallback на том же доверии, что и само слово, а `CarryBuffer.maxWords` = 3 ограничивает слепое удаление. Проактивный путь проверяет цепочку **до** правки, а не ретраит после: неудачная правка в терминале могла уже отправить keystroke'и, и вторая попытка отправила бы их дважды.
```

В разделе «Тесты» заменить первое предложение, добавив новый тестовый класс и новые кейсы:

```markdown
Покрыты только чистые функции: `TextConverterTests` (двусторонняя конвертация для обоих вариантов раскладки — `.pc` и `.apple`, регистр, цифры/символы не трогаются, все 33 буквы, «ё» на своей клавише для каждого варианта, отсутствие «протечки» между вариантами), `LanguageDetectorTests` (детект «ghbdtn»→привет, «руддщ»→hello, корректные слова не трогаются, короткие слова и слова с цифрами не трогаются, проактивные сигналы, скоры, слова-исключения в обе стороны для латиницы и кириллицы, влияние варианта раскладки на guard неоднозначных символов, критерий подхвата служебных слов в обе стороны) и `CarryBufferTests` (накопление и порядок, сброс, смена раскладки и варианта начинает новую цепочку, вытеснение самого старого звена при переполнении).
```

- [ ] **Step 5: Коммит кода и документации**

```bash
git add Sources/LatCyr/InputMonitor.swift CLAUDE.md
git commit -m "feat: carry function words on the proactive path, document the design"
```

- [ ] **Step 6: Собрать `.app` для ручной проверки**

Run: `./scripts/package-app.sh`
Expected: `dist/LatCyr.app` собран.

Напоминание: переупаковка меняет code hash и **сбрасывает выданные разрешения**. Выдать `dist/LatCyr.app` Accessibility и Input Monitoring заново в System Settings → Privacy & Security, затем `open dist/LatCyr.app`.

- [ ] **Step 7: Ручная проверка**

Системная часть (AX, event tap, keystroke-fallback) юнит-тестами не покрывается. Пройти список:

**TextEdit / Notes / Safari (AX-путь), английская раскладка активна:**
- [ ] `d ujhjl` + пробел → «в город»
- [ ] `b d ujhjlt` + пробел → «и в городе»
- [ ] `yfl ujhjljv` + пробел → «над городом» (трёхбуквенный предлог, который сам по себе не детектируется)
- [ ] `d yfxfkt` + пробел → «в начале» (проактивный путь: раскладка переключается на 2-м символе `yf`)
- [ ] `d, ujhjl` + пробел → «d, город» — предлог **не** тронут (разделитель не пробел)
- [ ] `d` + два пробела + `ujhjl` + пробел → предлог **не** тронут
- [ ] `cd ujhjl` + пробел → «cd город» — `cd` не служебное слово, не тронуто
- [ ] `d ujhjl` + Enter → «в город», Enter доходит до приложения
- [ ] набрать `d`, пробел, `ujhjl`, нажать Backspace до стирания пробела, продолжить — коррекция не хватает устаревшую цепочку

**Русская раскладка активна** (слова подобраны так, чтобы эвристика на них действительно срабатывала — «рщгыу»/house, например, не детектируется: `russianScore` 0.524):
- [ ] `шт цштвщц` + пробел → «in window»
- [ ] `еру ыныеуь` + пробел → «the system»
- [ ] `и цштвщц` + пробел → «и window» — русское «и» **не** тронуто (конверсия `b` не английское служебное слово)

**Terminal.app / iTerm2 (keystroke-fallback):**
- [ ] `d ujhjl` + пробел → «в город»
- [ ] `b d ujhjlt` + пробел → «и в городе»

**Обе русские раскладки:** повторить первый кейс при активной «Russian - PC» и при «Russian».

**Парольное поле** (любой сайт в Safari): набрать `d ujhjl` — ничего не меняется.

- [ ] **Step 8: Финальная верификация**

Run: `swift build && swift test && git status --short`
Expected: сборка чистая, все тесты зелёные, рабочее дерево чистое.
