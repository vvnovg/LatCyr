# Заглавные Б, Ю, Ж, Э, Х, Ъ — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Символы `<` `>` `:` `"` `{` `}` (и `~`/`|` для Ё) конвертируются в заглавные Б Ю Ж Э Х Ъ и обратно, не рвут буфер слова; хвостовой такой символ — всегда пунктуация, ведущий — заглавная буква, кроме токена в паре `"…"`, `{…}`, `<…>`.

**Architecture:** Таблица и наборы символов — в `TextConverter`. Выбор прочтения токена — новая чистая `LanguageDetector.wrongLayoutReading`. `InputMonitor` вызывает её на границе слова и передаёт готовую конверсию в `applyCorrection`; якорь, сверка и число Backspace по-прежнему считаются по токену целиком.

**Tech Stack:** Swift 5.9 Swift Package (без Xcode), XCTest, `scripts/eval-detector`.

**Spec:** `docs/superpowers/specs/2026-10-21-shifted-letter-keys-design.md`

## Global Constraints

- Пары: `<` Б, `>` Ю, `:` Ж, `"` Э, `{` Х, `}` Ъ — общие для `.pc` и `.apple`; Ё: `~` (`.pc`), `|` (`.apple`) — уже в таблицах.
- `ambiguousLetterSymbols(for:)` — единый источник набора для `InputMonitor.handle`, `TextFieldController.isBoundary`, `LanguageDetector.isScorable`.
- Хвостовая серия символов `shiftedLetterSymbols` — всегда пунктуация; ведущий символ — заглавная буква, кроме токена, обрамлённого парой (`"`…`"`, `{`…`}`, `<`…`>`, закрывающий — в хвосте): тогда открывающий — пунктуация; символы в середине — буквы. Оценки прочтений не сравниваются.
- Пороги (`llrThresholds`) и таблицы биграмм не меняются.
- Набранный текст в лог — только через `Sensitive(...)`.
- Коммиты — conventional style, окончание: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Проверено до плана

Замер `eval-detector words en` на строчных эквивалентах (регистр при скоринге не учитывается, `'`/`"` английская модель пропускает). Первая версия спеки выбирала прочтение по большему LLR; замер показал, что это путает частые слова, и спека переписана на правило по структуре (раздел 3 спеки):

| Набрано | Буква | Пунктуация | Правило по структуре |
|---|---|---|---|
| `{jhjij` | «Хорошо» 3.98 | «орошо» 4.26 | буква ✓ |
| `:fkm` | «Жаль» 2.61 | «аль» 3.00 | буква ✓ |
| `"njn` | «Этот» 1.67 (порог 1.5) | «тот» 2.52 | буква ✓ |
| `<skj` | «Было» 2.15 | «ыло» −0.24 | буква ✓ |
| `"ghbdtn"` | «Эпривет» 1.73 | «привет» 2.74 | пара → пунктуация ✓ |
| `"nj` | «Это» 1.75 (порог 2.5) | — | не ошибка без исключения |

«Это» (и строчное «это», `'nj`) детектор не ловит и сейчас — три буквы, порог 2.5. Пороги ради одного слова не подкручиваются (CLAUDE.md); путь — бандловое исключение, задача 5.

Найдено при этом: `isWrongLayout` сравнивает с исключениями конверсию **в регистре конвертера**. До этой фичи конверсия нижнего регистра всегда была нижней; с новыми парами `"` даёт заглавную «Э», и `exceptions.contains("Это")` промахнётся. Задача 2 приводит конверсию к нижнему регистру перед сравнением.

## Файлы

| Файл | Что |
|---|---|
| Modify `Sources/LatCyr/TextConverter.swift` | пары, `ambiguousLetterSymbols`, новая `shiftedLetterSymbols` |
| Modify `Tests/LatCyrTests/TextConverterTests.swift` | тесты пар и наборов |
| Modify `Sources/LatCyr/LanguageDetector.swift` | `Reading`, `wrongLayoutReading`, нижний регистр конверсии для исключений |
| Modify `Tests/LatCyrTests/LanguageDetectorTests.swift` | тесты прочтений |
| Modify `Sources/LatCyr/InputMonitor.swift` | вызов прочтения, `convertedWord` |
| Modify `scripts/eval-detector/main.swift` | детектор замера через прочтение |
| Modify `Resources/exceptions.txt` | «это» |
| Modify `CLAUDE.md`, спека | документация, результаты замера |

---

### Task 1: Таблица и наборы символов в `TextConverter`

**Files:**
- Modify: `Sources/LatCyr/TextConverter.swift` (таблица `sharedLatinToCyrillic` ~строки 18–25, `ambiguousLetterSymbols` ~строки 50–53)
- Test: `Tests/LatCyrTests/TextConverterTests.swift`

**Interfaces:**
- Produces: `TextConverter.shiftedLetterSymbols(for: RussianKeyboardVariant) -> Set<Character>`; `ambiguousLetterSymbols(for:)` теперь включает `shiftedLetterSymbols(for:)`.

- [ ] **Step 1: Падающие тесты** — в конец класса `TextConverterTests`

```swift
    // MARK: - Shifted punctuation keys (capital Б Ю Ж Э Х Ъ)

    private let shiftedPairs: [(String, String)] = [
        ("<", "Б"), (">", "Ю"), (":", "Ж"), ("\"", "Э"), ("{", "Х"), ("}", "Ъ"),
    ]

    func testShiftedKeysConvertBothWaysInBothVariants() {
        for variant in [TextConverter.RussianKeyboardVariant.pc, .apple] {
            for (latin, cyrillic) in shiftedPairs {
                XCTAssertEqual(TextConverter.toCyrillic(latin, variant: variant), cyrillic, "\(latin) \(variant)")
                XCTAssertEqual(TextConverter.toLatin(cyrillic, variant: variant), latin, "\(cyrillic) \(variant)")
            }
        }
    }

    func testLowercasePunctuationPairsUnchanged() {
        XCTAssertEqual(TextConverter.toLatin("б", variant: .pc), ",")
        XCTAssertEqual(TextConverter.toLatin("Б", variant: .pc), "<")
        XCTAssertEqual(TextConverter.toCyrillic(",", variant: .pc), "б")
        XCTAssertEqual(TextConverter.toCyrillic("<", variant: .pc), "Б")
    }

    func testShiftedWordsBothDirections() {
        XCTAssertEqual(TextConverter.toLatin("БвшмЮ", variant: .pc), "<div>")
        XCTAssertEqual(TextConverter.toLatin("цщкдвЖ", variant: .apple), "world:")
        XCTAssertEqual(TextConverter.toCyrillic("{jhjij", variant: .pc), "Хорошо")
    }

    func testShiftedSymbolsAreAmbiguousLetterSymbols() {
        for variant in [TextConverter.RussianKeyboardVariant.pc, .apple] {
            let shifted = TextConverter.shiftedLetterSymbols(for: variant)
            XCTAssertTrue(shifted.isSubset(of: TextConverter.ambiguousLetterSymbols(for: variant)))
            XCTAssertTrue(shifted.isSuperset(of: ["<", ">", ":", "\"", "{", "}"]))
        }
        XCTAssertTrue(TextConverter.shiftedLetterSymbols(for: .pc).contains("~"))
        XCTAssertFalse(TextConverter.shiftedLetterSymbols(for: .pc).contains("|"))
        XCTAssertTrue(TextConverter.shiftedLetterSymbols(for: .apple).contains("|"))
        XCTAssertFalse(TextConverter.shiftedLetterSymbols(for: .apple).contains("~"))
    }
```

- [ ] **Step 2: Убедиться, что падают**

Run: `swift test --filter TextConverterTests`
Expected: FAIL — `shiftedLetterSymbols` не найдена (ошибка компиляции).

- [ ] **Step 3: Реализация**

В `sharedLatinToCyrillic` добавить строку после `"m": "ь", ",": "б", ".": "ю",`:

```swift
        // Shift on the same keys: the capitals of the letters above. Exact
        // entries, because convert's lowercase path would lift "б" to "Б"
        // but map "Б" back to ","; with these, "Б" → "<" and "<" → "Б".
        "<": "Б", ">": "Ю", ":": "Ж", "\"": "Э", "{": "Х", "}": "Ъ",
```

`ambiguousLetterSymbols(for:)` заменить на:

```swift
    public static func ambiguousLetterSymbols(for variant: RussianKeyboardVariant) -> Set<Character> {
        let base: Set<Character> = [",", ".", ";", "'", "[", "]"]
        return (variant == .pc ? base.union(["`"]) : base.union(["\\"]))
            .union(shiftedLetterSymbols(for: variant))
    }

    /// The Shift layer of the punctuation keys that are Russian letters —
    /// capital Б Ю Ж Э Х Ъ and Ё. Unlike the unshifted ones, these are mostly
    /// punctuation at the end of a word ("word:", a closing quote) and capitals
    /// at its start ("Это"), which LanguageDetector.wrongLayoutReading decides
    /// per token.
    public static func shiftedLetterSymbols(for variant: RussianKeyboardVariant) -> Set<Character> {
        let base: Set<Character> = ["<", ">", ":", "\"", "{", "}"]
        return variant == .pc ? base.union(["~"]) : base.union(["|"])
    }
```

- [ ] **Step 4: Тесты**

Run: `swift test --filter TextConverterTests`, затем `swift test`
Expected: PASS. Если в полном прогоне упал тест другого класса (например, на неоднозначные символы в `LanguageDetectorTests` или `ExtendRangeTests`), не меняй его ожидание молча: запиши, какой тест и почему, и сообщи как DONE_WITH_CONCERNS.

- [ ] **Step 5: Коммит**

```bash
git add Sources/LatCyr/TextConverter.swift Tests/LatCyrTests/TextConverterTests.swift
git commit -m "feat: convert shifted letter keys (capital Б Ю Ж Э Х Ъ)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `LanguageDetector.wrongLayoutReading`

**Files:**
- Modify: `Sources/LatCyr/LanguageDetector.swift` (рядом с `isWrongLayout`, ~строка 133)
- Test: `Tests/LatCyrTests/LanguageDetectorTests.swift`

**Interfaces:**
- Consumes: `TextConverter.shiftedLetterSymbols(for:)` (Task 1).
- Produces: `public struct LanguageDetector.Reading: Equatable { public let prefix: String; public let core: String; public let suffix: String }`; `public static func wrongLayoutReading(token: String, currentLayoutIsRussian: Bool, exceptions: Set<String>, variant: TextConverter.RussianKeyboardVariant) -> Reading?`.

- [ ] **Step 1: Падающие тесты** — в конец класса `LanguageDetectorTests`

```swift
    // MARK: - wrongLayoutReading (shifted letter keys)

    private func reading(_ token: String, russian: Bool = false, exceptions: Set<String> = [],
                         variant: TextConverter.RussianKeyboardVariant = .pc) -> LanguageDetector.Reading? {
        LanguageDetector.wrongLayoutReading(token: token, currentLayoutIsRussian: russian,
                                            exceptions: exceptions, variant: variant)
    }

    func testLeadingShiftedSymbolIsCapital() {
        XCTAssertEqual(reading("{jhjij"), .init(prefix: "", core: "{jhjij", suffix: ""))
        XCTAssertEqual(reading(":fkm"), .init(prefix: "", core: ":fkm", suffix: ""))
        XCTAssertEqual(reading("<skj"), .init(prefix: "", core: "<skj", suffix: ""))
        XCTAssertEqual(reading("\"njn"), .init(prefix: "", core: "\"njn", suffix: ""))
    }

    func testTrailingShiftedSymbolsAreAlwaysPunctuation() {
        XCTAssertEqual(reading("ghbdtn:"), .init(prefix: "", core: "ghbdtn", suffix: ":"))
        XCTAssertEqual(reading("ghbdtn\"}"), .init(prefix: "", core: "ghbdtn", suffix: "\"}"))
    }

    func testWrappedTokenOpeningSymbolIsPunctuation() {
        XCTAssertEqual(reading("\"ghbdtn\""), .init(prefix: "\"", core: "ghbdtn", suffix: "\""))
        XCTAssertEqual(reading("{jhjij}"), .init(prefix: "{", core: "jhjij", suffix: "}"))
    }

    func testUnclosedQuoteIsCapitalKnownLimitation() {
        // The first of several quoted words has no closing quote in its token.
        XCTAssertEqual(reading("\"ghbdtn"), .init(prefix: "", core: "\"ghbdtn", suffix: ""))
    }

    func testMismatchedPairIsNotWrapping() {
        // "{" opens, but the tail holds a quote, not "}": "{" stays a capital.
        XCTAssertEqual(reading("{jhjij\""), .init(prefix: "", core: "{jhjij", suffix: "\""))
    }

    func testEnglishWithShiftedSymbolsUntouched() {
        XCTAssertNil(reading("\"hello\""))
        XCTAssertNil(reading("foo:bar"))
        XCTAssertNil(reading("hello:"))
    }

    func testOnlyShiftedSymbolsIsNil() {
        XCTAssertNil(reading("\"::"))
    }

    func testThreeLetterCapitalNeedsException() {
        // "это" scores 1.75 against the 2.5 three-letter threshold.
        XCTAssertNil(reading("\"nj"))
        // The conversion "Это" is compared with exceptions lowercased.
        XCTAssertEqual(reading("\"nj", exceptions: ["это"]), .init(prefix: "", core: "\"nj", suffix: ""))
    }

    func testRussianLayoutShiftedPunctuation() {
        // Russian layout: Ж is a letter (converted to ":"); a real ":" or quote
        // typed with Shift+6 / Shift+2 is punctuation.
        XCTAssertEqual(reading("руддщ:", russian: true), .init(prefix: "", core: "руддщ", suffix: ":"))
        XCTAssertEqual(reading("\"руддщ\"", russian: true), .init(prefix: "\"", core: "руддщ", suffix: "\""))
        XCTAssertEqual(reading("цщкдвЖ", russian: true), .init(prefix: "", core: "цщкдвЖ", suffix: ""))
    }

    func testPlainWordUnchanged() {
        XCTAssertEqual(reading("ghbdtn"), .init(prefix: "", core: "ghbdtn", suffix: ""))
        XCTAssertNil(reading("hello"))
    }
```

- [ ] **Step 2: Убедиться, что падают**

Run: `swift test --filter LanguageDetectorTests`
Expected: FAIL — `wrongLayoutReading` / `Reading` не найдены.

- [ ] **Step 3: Реализация**

а) В `isWrongLayout` строку `let converted = convert(lower, ...)` заменить на:

```swift
        // Lowercased: the shifted keys convert to capitals ("\"" → "Э"),
        // and exceptions are stored lowercase.
        let converted = convert(lower, currentLayoutIsRussian: currentLayoutIsRussian, variant: variant).lowercased()
```

б) Сразу после `isWrongLayout` добавить:

```swift
    /// How a typed token splits for correction: `core` is converted, `prefix`
    /// and `suffix` are punctuation left as typed. See wrongLayoutReading.
    public struct Reading: Equatable {
        public let prefix: String
        public let core: String
        public let suffix: String
    }

    /// Opening shifted symbols and the closer that makes them a pair.
    private static let wrappingPairs: [Character: Character] = ["\"": "\"", "{": "}", "<": ">"]

    /// The reading of `token` if it is a wrong-layout word, or nil.
    ///
    /// The Shift layer of the letter keys (TextConverter.shiftedLetterSymbols:
    /// "<" Б, ":" Ж, "\"" Э …) is read by position, not by score. A trailing
    /// run is always punctuation — no word ends in a capital, while "word:"
    /// and a closing quote are everyday. A leading one is a capital
    /// («Хорошо», «Этот»), unless the token is wrapped — opens with "\"",
    /// "{" or "<" and its tail holds the matching closer — and then it is
    /// punctuation ("\"привет\""). Comparing the LLR of both readings does
    /// not work: the mean per letter pair favours the word without its first
    /// letter ("{орошо" over «Хорошо», "\"тот" over «Этот»). In the middle a
    /// symbol stays a letter, like ";" in "ckj;yj" («сложно»).
    public static func wrongLayoutReading(
        token: String, currentLayoutIsRussian: Bool,
        exceptions: Set<String>, variant: TextConverter.RussianKeyboardVariant
    ) -> Reading? {
        let shifted = TextConverter.shiftedLetterSymbols(for: variant)
        var body = Substring(token)
        var suffixStart = body.endIndex
        while suffixStart > body.startIndex, shifted.contains(body[body.index(before: suffixStart)]) {
            suffixStart = body.index(before: suffixStart)
        }
        let suffix = String(body[suffixStart...])
        body = body[..<suffixStart]
        guard !body.isEmpty else { return nil }

        var prefix = ""
        if let first = body.first, body.count > 1,
           let closer = wrappingPairs[first], suffix.contains(closer) {
            prefix = String(first)
            body = body.dropFirst()
        }
        let reading = Reading(prefix: prefix, core: String(body), suffix: suffix)
        return isWrongLayout(word: reading.core, currentLayoutIsRussian: currentLayoutIsRussian,
                             exceptions: exceptions, variant: variant) ? reading : nil
    }
```

- [ ] **Step 4: Тесты**

Run: `swift test --filter LanguageDetectorTests`, затем `swift test`
Expected: PASS. Если какое-то ожидание не совпало, **не меняй тест**: запиши фактический результат и, для оценочных случаев, LLR (`.build/eval/eval-detector words en ...` после сборки с изменёнными исходниками, команда в CLAUDE.md) и сообщи DONE_WITH_CONCERNS.

- [ ] **Step 5: Коммит**

```bash
git add Sources/LatCyr/LanguageDetector.swift Tests/LatCyrTests/LanguageDetectorTests.swift
git commit -m "feat: read shifted letter keys by position in the token

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `InputMonitor` — прочтение на границе слова

**Files:**
- Modify: `Sources/LatCyr/InputMonitor.swift` (граница слова ~364–406; `scheduleRetroactiveCheck` ~541; `applyCorrectionNow` ~649; `applyCorrection` ~746–811)

**Interfaces:**
- Consumes: `LanguageDetector.wrongLayoutReading(token:currentLayoutIsRussian:exceptions:variant:) -> Reading?` (Task 2).
- Produces: параметр `convertedWord: String?` у `scheduleRetroactiveCheck`, `applyCorrectionNow`, `applyCorrection` (по умолчанию `nil` = конверсия всего слова, как раньше).

Юнит-тестов нет (обёртка над tap, проверяется вручную); критерий — сборка без новых предупреждений и зелёный `swift test`.

- [ ] **Step 1: Вспомогательная конверсия** — добавить в `InputMonitor` рядом с `switchLayout`:

```swift
    private func convert(_ text: String, wasRussian: Bool, variant: TextConverter.RussianKeyboardVariant) -> String {
        wasRussian ? TextConverter.toLatin(text, variant: variant) : TextConverter.toCyrillic(text, variant: variant)
    }
```

- [ ] **Step 2: Граница слова** — заменить вычисление `wrong` (~364–367):

```swift
            // The token is replaced whole (anchor, deletion count); only the
            // text that goes in depends on how its shifted-key punctuation
            // reads — see LanguageDetector.wrongLayoutReading.
            let reading = currentWord.isEmpty ? nil : LanguageDetector.wrongLayoutReading(
                token: currentWord, currentLayoutIsRussian: currentLayoutIsRussian,
                exceptions: exceptionStore.words, variant: currentRussianVariant
            )
            let wrong = !currentWord.isEmpty && (reading != nil || isTerminalCommand())
            let convertedWord = reading.map {
                $0.prefix + convert($0.core, wasRussian: currentLayoutIsRussian, variant: currentRussianVariant) + $0.suffix
            }
```

В вызовы `applyCorrectionNow(...)` и `scheduleRetroactiveCheck(...)` в ветке `wrong` добавить аргумент `convertedWord: convertedWord`.

- [ ] **Step 3: Протянуть параметр**
  - `scheduleRetroactiveCheck(...)`: добавить параметр `convertedWord: String?` и передать его в `applyCorrection(..., convertedWord: convertedWord, ...)` внутри `asyncAfter`.
  - `applyCorrectionNow(...)`: добавить параметр `convertedWord: String?` и передать в `applyCorrection`.
  - `applyCorrection(...)`: добавить параметр `convertedWord: String? = nil` (после `replacePrefix`). Вычисление `converted` (~757–758) заменить на:

```swift
        let span = (carried + [word]).joined(separator: " ")
        // The chain converts link by link (the space is in neither table);
        // the word comes pre-split by its reading when the caller has one.
        let wordConverted = convertedWord ?? convert(word, wasRussian: wasRussian, variant: variant)
        let converted = (carried.map { convert($0, wasRussian: wasRussian, variant: variant) } + [wordConverted])
            .joined(separator: " ")
```

  - В ветке повтора только по слову (~807) заменить `let convertedWord = wasRussian ? TextConverter.toLatin(word, ...) : TextConverter.toCyrillic(word, ...)` на `let retryWord = wordConverted` и использовать `retryWord` в `replaceAnchoredWord(wordAnchor, word: word, with: retryWord)` и в строке лога.

Проактивный путь `applyCorrection(...replacePrefix: true...)` не меняется — `convertedWord` по умолчанию `nil`.

- [ ] **Step 4: Сборка и тесты**

Run: `swift build && swift test`
Expected: без предупреждений, все тесты PASS.

- [ ] **Step 5: Коммит**

```bash
git add Sources/LatCyr/InputMonitor.swift
git commit -m "feat: correct tokens with shifted letter keys by their reading

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Замер детектора до и после

**Files:**
- Modify: `scripts/eval-detector/main.swift` (замыкание `detector`, ~строки 68–70)
- Modify: `docs/superpowers/specs/2026-10-21-shifted-letter-keys-design.md`

Данные не в git: `.build/frequencywords/` (скачать) и `.build/eval/` (проверочные половины пересоздаёт `gen-bigrams`).

- [ ] **Step 1: Данные**

```bash
mkdir -p .build/frequencywords .build/eval
curl -sSfL -o .build/frequencywords/ru_50k.txt https://raw.githubusercontent.com/hermitdave/FrequencyWords/525f9b560de45753a5ea01069454e72e9aa541c6/content/2018/ru/ru_50k.txt
curl -sSfL -o .build/frequencywords/en_50k.txt https://raw.githubusercontent.com/hermitdave/FrequencyWords/525f9b560de45753a5ea01069454e72e9aa541c6/content/2018/en/en_50k.txt
printf '%s  %s\n' 6095f507cc167488ec66ada5a85ac50433503a08ad24a07c6eabdf54352c4e7f .build/frequencywords/ru_50k.txt 5351ff405b1126ef555791dd4d9798a48e3e9a501a9fc481a9da957752cfb458 .build/frequencywords/en_50k.txt | shasum -a 256 -c
swiftc -O -o .build/gen-bigrams scripts/gen-bigrams.swift
.build/gen-bigrams .build/frequencywords/ru_50k.txt .build/frequencywords/en_50k.txt .build/eval > .build/eval/BigramTables.regen.swift
cmp .build/eval/BigramTables.regen.swift Sources/LatCyr/BigramTables.swift
```

Expected: оба `OK`; `cmp` без вывода (таблицы воспроизводятся байт в байт — значит, и проверочные половины те же, что при выборе порогов). Если `cmp` нашёл различие — остановиться и сообщить BLOCKED.

- [ ] **Step 2: Базовая линия — исходники до фичи**

```bash
mkdir -p .build/eval/before
for f in LanguageDetector TextConverter BigramModel BigramTables; do git show 73bd4da:Sources/LatCyr/$f.swift > .build/eval/before/$f.swift; done
git show 73bd4da:scripts/eval-detector/main.swift > .build/eval/before/main.swift
swiftc -O -o .build/eval/eval-before .build/eval/before/LanguageDetector.swift .build/eval/before/TextConverter.swift .build/eval/before/BigramModel.swift .build/eval/before/BigramTables.swift .build/eval/before/main.swift
D="scripts/eval-data/man-tokens.txt scripts/eval-data/ru-dict.txt .build/eval/ru_holdout.txt .build/eval/en_holdout.txt Resources/exceptions.txt .build/frequencywords/ru_50k.txt .build/frequencywords/en_50k.txt"
.build/eval/eval-before report $D > .build/eval/report-before.txt
```

- [ ] **Step 3: Детектор замера — через прочтение**

В `scripts/eval-detector/main.swift` замыкание `detector` заменить на:

```swift
// What InputMonitor decides on now: the token's best reading (identical to
// isWrongLayout for tokens without shifted letter keys). curve keeps
// isWrongLayout — it sweeps thresholds, which the reading doesn't change.
let detector: Decide = { typed, russianActive, variant in
    LanguageDetector.wrongLayoutReading(token: typed, currentLayoutIsRussian: russianActive, exceptions: [], variant: variant) != nil
}
```

- [ ] **Step 4: Замер после**

```bash
swiftc -O -o .build/eval/eval-detector Sources/LatCyr/LanguageDetector.swift Sources/LatCyr/TextConverter.swift Sources/LatCyr/BigramModel.swift Sources/LatCyr/BigramTables.swift scripts/eval-detector/main.swift
.build/eval/eval-detector report $D > .build/eval/report-after.txt
diff .build/eval/report-before.txt .build/eval/report-after.txt
```

- [ ] **Step 5: Оценка и запись в спеку**

В спеке раздел «Тесты» дополнить подразделом «Результаты замера»: строки отчёта, которые изменились (или «отчёт идентичен»), с числами до/после. Критерий: доля ложных срабатываний ни в одном наборе не выросла больше чем на 0,1 процентного пункта. Если выросла — **не коммитить скрипт**, сообщить DONE_WITH_CONCERNS с изменившимися строками и примерами токенов (`.build/eval/eval-detector flagged en scripts/eval-data/man-tokens.txt | head -50`).


- [ ] **Step 6: Коммит**

```bash
git add scripts/eval-detector/main.swift docs/superpowers/specs/2026-10-21-shifted-letter-keys-design.md
git commit -m "test: measure the detector through wrongLayoutReading

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Исключение «это» и документация

**Files:**
- Modify: `Resources/exceptions.txt`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Исключение**

Добавить строку `это` в `Resources/exceptions.txt` рядом с другими частыми русскими словами («будут», «также»). `BundledExceptionsTests` сам проверит: кириллическая запись, набранная верно, не исправляется в обоих вариантах.

Run: `swift test --filter BundledExceptionsTests`, затем `.build/eval/eval-detector words en "'nj"` (после пересборки по команде из CLAUDE.md — эта команда меряет без исключений, поэтому ожидается по-прежнему `pc=false`; исключение действует в приложении).
Expected: PASS.

- [ ] **Step 2: CLAUDE.md**
  - В пункте «**`TextConverter.RussianKeyboardVariant` и `ambiguousLetterSymbols(for:)`**» добавить: набор включает и Shift-слой этих клавиш (`shiftedLetterSymbols`: `<` `>` `:` `"` `{` `}` и Ё — `~`/`|` по варианту), их пары — заглавные Б Ю Ж Э Х Ъ.
  - Новый пункт в «Ключевые решения»: «**Shift-слой буквенных клавиш читается по позиции (`LanguageDetector.wrongLayoutReading`):** хвостовая серия — всегда пунктуация, ведущий символ — заглавная буква, кроме токена в паре `"…"`, `{…}`, `<…>` (тогда пунктуация), в середине — буква. Оценки двух прочтений не сравниваются: среднее на пару букв систематически предпочитает слово без первой буквы («{орошо» над «Хорошо», `"тот` над «Этот»). Известное ограничение: кавычка перед первым из нескольких слов без пары в том же токене читается как «Э». `InputMonitor` заменяет токен целиком (якорь, Backspace), а текст замены — `prefix + конверсия(core) + suffix` через параметр `convertedWord` у `applyCorrection`. Конверсия сравнивается с исключениями в нижнем регистре: `\"` даёт заглавную «Э». Спека — `docs/superpowers/specs/2026-10-21-shifted-letter-keys-design.md`.»
  - В «Тесты»: в описание `TextConverterTests` — пары Shift-слоя в обе стороны и наборы; в описание `LanguageDetectorTests` — прочтения `wrongLayoutReading`.
  - В список бандловых исключений (абзац про `ExceptionStore`) — «это» среди частых русских слов.

- [ ] **Step 3: Тесты и коммит**

Run: `swift test`
Expected: PASS.

```bash
git add Resources/exceptions.txt CLAUDE.md
git commit -m "docs: document shifted letter keys; add «это» to bundled exceptions

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Ручная проверка (после всех задач)

Упаковать (`./scripts/package-app.sh`), поставить в `/Applications`, проверить:
- TextEdit, английская раскладка: `{jhjij ` → «Хорошо», `:fkm ` → «Жаль», `<skj ` → «Было», `"njn ` → «Этот», `"nj ` → «Это», `"ghbdtn" ` → `"привет"`, `ghbdtn: ` → «привет:».
- TextEdit, английский текст: `"hello" `, `foo:bar `, `hello: ` — не трогаются.
- Terminal, русская раскладка: `БвшмЮ ` → `<div>`; в терминале Claude Desktop — то же.
