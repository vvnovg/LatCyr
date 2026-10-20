# Исправить и запомнить (двойной Shift) — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Двойной Shift и пункт меню исправляют пропущенное слово (выделенное или стоящее прямо перед последним автоисправлением) и добавляют исправленную форму в исключения.

**Architecture:** Две новые чистые части — `DoubleShiftDetector` (распознаёт ⇧⇧ по событиям) и `ManualFix.plan` (направление, конверсия, слово для исключений) — под юнит-тестами. `InputMonitor` начинает слушать `flagsChanged`, помнит предыдущее слово и после каждого успешного автоисправления сохраняет кандидата `PendingFix`. Новый класс `ManualFixer` выполняет действие: AX-замена выделения или кандидата, в гибридных приложениях и терминалах — нажатия.

**Tech Stack:** Swift 5.9 Swift Package (без Xcode), AppKit, ApplicationServices (AX), CoreGraphics (CGEventTap), XCTest.

**Spec:** `docs/superpowers/specs/2026-10-20-fix-and-remember-design.md`

## Global Constraints

- macOS 14+, `swift build` / `swift test` из корня репозитория; новые файлы — в `Sources/LatCyr/` и `Tests/LatCyrTests/`, тесты через `@testable import LatCyr`.
- Набранный текст в лог — только через `Sensitive(...)`, никогда голой строкой.
- В callback'е event tap — ничего тяжёлого: AX-запись, буфер обмена, звук и окна только на главной очереди через `DispatchQueue.main.async`.
- Синтетические события LatCyr (метка `KeystrokeSimulator.eventMarker`) игнорируются и для `flagsChanged`.
- `maxPress` = 0,3 с, `maxGap` = 0,3 с; срабатывание на втором отпускании Shift.
- Исключение — исправленная форма в нижнем регистре; после ручного исправления раскладка не переключается.
- Коммиты — conventional style (`feat:`, `fix:`, `docs:`, `test:`), окончание сообщения: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Уточнения к спеке, принятые в плане

План вносит три изменения в спеку. Задача 7 правит текст спеки соответственно.

1. **Вместо новой `previousWordRange` — существующая `extendRange`.** Найти слово прямо перед span'ом через ровно один пробел с границей перед словом — ровно то, что делает `extendRange(_:backwardOver:[word]...)`. Новая AX-обёртка `previousWordAnchor` вызывает её. Тесты на этот сценарий добавляются в `ExtendRangeTests`.
2. **В гибридных приложениях и терминалах кандидат проверяется раньше выделения.** Выделение там читается синтетическим Cmd+C, а VS Code и ряд редакторов без выделения копируют всю текущую строку. Ввод «замены» поверх такой копии вставил бы текст, ничего не заменив. Кандидат годен только сразу после автоисправления, когда выделения у пользователя почти наверняка нет. Скопированный текст с переводом строки отклоняется.
3. **Один `ClipboardReader` на приложение.** Его защита от повторного входа работает в пределах экземпляра, поэтому `InputMonitor` владеет им и отдаёт его `AppDelegate`.

## Файлы

| Файл | Что |
|---|---|
| Create `Sources/LatCyr/DoubleShiftDetector.swift` | чистый автомат ⇧⇧ |
| Create `Tests/LatCyrTests/DoubleShiftDetectorTests.swift` | его тесты |
| Create `Sources/LatCyr/ManualFix.swift` | чистая `ManualFix.plan` |
| Create `Tests/LatCyrTests/ManualFixTests.swift` | её тесты |
| Modify `Sources/LatCyr/TextFieldController.swift` | `selectionAnchor()`, `previousWordAnchor(before:word:variant:)` |
| Modify `Tests/LatCyrTests/ExtendRangeTests.swift` | сценарий «предыдущее слово» |
| Create `Sources/LatCyr/PendingFix.swift` | `PreviousWord`, `PendingFix` |
| Modify `Sources/LatCyr/InputMonitor.swift` | `flagsChanged`, детектор, `previousWord`, `pendingFix`, `fixAndRemember` |
| Create `Sources/LatCyr/ManualFixer.swift` | выполнение действия |
| Modify `Sources/LatCyr/AppDelegate.swift` | пункт меню, общий `ClipboardReader` |
| Modify `CLAUDE.md`, `docs/superpowers/specs/2026-10-20-fix-and-remember-design.md` | документация |

---

### Task 1: `DoubleShiftDetector`

**Files:**
- Create: `Sources/LatCyr/DoubleShiftDetector.swift`
- Test: `Tests/LatCyrTests/DoubleShiftDetectorTests.swift`

**Interfaces:**
- Produces: `struct DoubleShiftDetector` с `enum Input { case shiftDown, shiftUp, otherKey }`, `static let maxPress: TimeInterval`, `static let maxGap: TimeInterval`, `mutating func feed(_ input: Input, at time: TimeInterval) -> Bool` (true — сработал).

- [ ] **Step 1: Написать падающие тесты**

```swift
import XCTest
@testable import LatCyr

final class DoubleShiftDetectorTests: XCTestCase {
    private var detector = DoubleShiftDetector()

    /// Feeds a sequence of (input, time) and returns the index of every event that fired.
    private func fired(_ events: [(DoubleShiftDetector.Input, TimeInterval)]) -> [Int] {
        var result: [Int] = []
        for (index, event) in events.enumerated() where detector.feed(event.0, at: event.1) {
            result.append(index)
        }
        return result
    }

    func testQuickDoubleShiftFiresOnSecondRelease() {
        XCTAssertEqual(fired([(.shiftDown, 0), (.shiftUp, 0.1), (.shiftDown, 0.2), (.shiftUp, 0.3)]), [3])
    }

    func testSlowPressDoesNotFire() {
        XCTAssertEqual(fired([(.shiftDown, 0), (.shiftUp, 0.5), (.shiftDown, 0.6), (.shiftUp, 0.7)]), [])
    }

    func testSlowSecondPressDoesNotFire() {
        XCTAssertEqual(fired([(.shiftDown, 0), (.shiftUp, 0.1), (.shiftDown, 0.2), (.shiftUp, 0.6)]), [])
    }

    func testLongGapDoesNotFire() {
        XCTAssertEqual(fired([(.shiftDown, 0), (.shiftUp, 0.1), (.shiftDown, 0.5), (.shiftUp, 0.6)]), [])
    }

    func testLongGapStartsANewPairThatCanFire() {
        // The late press is the first press of a fresh pair.
        XCTAssertEqual(fired([
            (.shiftDown, 0), (.shiftUp, 0.1),
            (.shiftDown, 0.5), (.shiftUp, 0.6), (.shiftDown, 0.7), (.shiftUp, 0.8),
        ]), [5])
    }

    func testShiftForCapitalLetterDoesNotCount() {
        // Shift+G, then a lone Shift: the letter breaks the pair.
        XCTAssertEqual(fired([
            (.shiftDown, 0), (.otherKey, 0.05), (.shiftUp, 0.1),
            (.shiftDown, 0.2), (.shiftUp, 0.3),
        ]), [])
    }

    func testOtherKeyBetweenPressesResets() {
        XCTAssertEqual(fired([(.shiftDown, 0), (.shiftUp, 0.1), (.otherKey, 0.15), (.shiftDown, 0.2), (.shiftUp, 0.3)]), [])
    }

    func testTripleShiftFiresOnce() {
        XCTAssertEqual(fired([
            (.shiftDown, 0), (.shiftUp, 0.1), (.shiftDown, 0.2), (.shiftUp, 0.3),
            (.shiftDown, 0.4), (.shiftUp, 0.5),
        ]), [3])
    }

    func testFourQuickPressesFireTwice() {
        XCTAssertEqual(fired([
            (.shiftDown, 0), (.shiftUp, 0.1), (.shiftDown, 0.2), (.shiftUp, 0.3),
            (.shiftDown, 0.4), (.shiftUp, 0.5), (.shiftDown, 0.6), (.shiftUp, 0.7),
        ]), [3, 7])
    }

    func testStrayReleaseIsIgnored() {
        // A release with no press seen (tap started while Shift was held).
        XCTAssertEqual(fired([(.shiftUp, 0), (.shiftDown, 0.1), (.shiftUp, 0.2), (.shiftDown, 0.3), (.shiftUp, 0.4)]), [4])
    }
}
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `swift test --filter DoubleShiftDetectorTests`
Expected: FAIL — ошибка компиляции `cannot find 'DoubleShiftDetector' in scope`.

- [ ] **Step 3: Реализация**

```swift
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
```

- [ ] **Step 4: Убедиться, что тесты проходят**

Run: `swift test --filter DoubleShiftDetectorTests`
Expected: PASS, 10 тестов.

- [ ] **Step 5: Коммит**

```bash
git add Sources/LatCyr/DoubleShiftDetector.swift Tests/LatCyrTests/DoubleShiftDetectorTests.swift
git commit -m "feat: add DoubleShiftDetector for the fix-and-remember hotkey

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `ManualFix.plan`

**Files:**
- Create: `Sources/LatCyr/ManualFix.swift`
- Test: `Tests/LatCyrTests/ManualFixTests.swift`

**Interfaces:**
- Consumes: `TextConverter.toCyrillic(_:variant:)`, `TextConverter.toLatin(_:variant:)`, `ExceptionWord.normalized(from:)` (существующие).
- Produces: `enum ManualFix { struct Plan: Equatable { let replacement: String; let exception: String }; static func plan(for text: String, variant: TextConverter.RussianKeyboardVariant) -> Plan? }`.

Правило направления. Источник целиком из кириллических букв → в латиницу. Источник без единой кириллической буквы → в кириллицу; латинская запись русского слова законно содержит пунктуацию (`;` — «ж», `,` — «б»), поэтому проверяется не источник, а **результат**: он должен пройти `ExceptionWord.normalized` и оказаться в другом алфавите. Смешанный источник → `nil`.

- [ ] **Step 1: Написать падающие тесты**

```swift
import XCTest
@testable import LatCyr

final class ManualFixTests: XCTestCase {
    func testLatinTypedRussianWordBecomesCyrillic() {
        XCTAssertEqual(ManualFix.plan(for: "ubarf", variant: .pc), .init(replacement: "гифка", exception: "гифка"))
        XCTAssertEqual(ManualFix.plan(for: "ubarf", variant: .apple), .init(replacement: "гифка", exception: "гифка"))
    }

    func testPunctuationKeysThatAreRussianLetters() {
        // ";" is the ж key, "," and "<" the б key.
        XCTAssertEqual(ManualFix.plan(for: "ckj;yj", variant: .pc)?.replacement, "сложно")
        XCTAssertEqual(ManualFix.plan(for: "<s", variant: .pc)?.replacement, "Бы")
    }

    func testCyrillicTypedEnglishWordBecomesLatin() {
        XCTAssertEqual(ManualFix.plan(for: "пше", variant: .pc), .init(replacement: "git", exception: "git"))
    }

    func testCaseIsKeptInReplacementAndLoweredInException() {
        XCTAssertEqual(ManualFix.plan(for: "Ubarf", variant: .pc), .init(replacement: "Гифка", exception: "гифка"))
        XCTAssertEqual(ManualFix.plan(for: "Пше", variant: .pc), .init(replacement: "Git", exception: "git"))
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(ManualFix.plan(for: " ubarf\n", variant: .pc)?.replacement, "гифка")
    }

    func testRejectsSeveralWords() {
        XCTAssertNil(ManualFix.plan(for: "ubarf yflj", variant: .pc))
    }

    func testRejectsMixedAlphabets() {
        // Cyrillic "а" inside a Latin word.
        XCTAssertNil(ManualFix.plan(for: "ubаrf", variant: .pc))
    }

    func testRejectsDigits() {
        XCTAssertNil(ManualFix.plan(for: "ubar1", variant: .pc))
    }

    func testRejectsResultWithPunctuation() {
        // "ж" converts to ";" — not a valid Latin word.
        XCTAssertNil(ManualFix.plan(for: "жук", variant: .pc))
    }

    func testRejectsEmpty() {
        XCTAssertNil(ManualFix.plan(for: "", variant: .pc))
        XCTAssertNil(ManualFix.plan(for: "  ", variant: .pc))
    }
}
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `swift test --filter ManualFixTests`
Expected: FAIL — `cannot find 'ManualFix' in scope`.

- [ ] **Step 3: Реализация**

```swift
import Foundation

/// What "fix and remember" does to a word: which way to convert it, the
/// replacement for the text, and the word to add to the exceptions. Pure,
/// unit-tested; ManualFixer does the AX and keystroke work around it.
enum ManualFix {
    struct Plan: Equatable {
        /// Conversion with each letter's case kept — goes into the text.
        let replacement: String
        /// The corrected form, lowercased — goes into ExceptionStore, so the
        /// mistyped form is always corrected from now on and the corrected
        /// one is never touched.
        let exception: String
    }

    /// nil when `text` is not one word in one alphabet.
    ///
    /// The source is not validated with ExceptionWord: a Russian word typed
    /// in the English layout legitimately contains punctuation keys (";" is
    /// "ж", "," is "б"). The *result* is — it must be a clean word in the
    /// other alphabet.
    static func plan(for text: String, variant: TextConverter.RussianKeyboardVariant) -> Plan? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !source.contains(where: \.isWhitespace) else { return nil }
        let cyrillicCount = source.unicodeScalars.filter(isCyrillicLetter).count
        let toLatin: Bool
        if cyrillicCount == source.unicodeScalars.count {
            toLatin = true
        } else if cyrillicCount == 0 {
            toLatin = false
        } else {
            return nil
        }
        let replacement = toLatin
            ? TextConverter.toLatin(source, variant: variant)
            : TextConverter.toCyrillic(source, variant: variant)
        guard let exception = ExceptionWord.normalized(from: replacement) else { return nil }
        // The result must have changed alphabet: a Latin source whose
        // conversion is still Latin (digits, unmapped symbols) is no fix.
        let resultIsCyrillic = exception.unicodeScalars.allSatisfy(isCyrillicLetter)
        guard resultIsCyrillic != toLatin else { return nil }
        return Plan(replacement: replacement, exception: exception)
    }

    private static func isCyrillicLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x0410...0x044F).contains(scalar.value) || scalar.value == 0x0401 || scalar.value == 0x0451
    }
}
```

- [ ] **Step 4: Убедиться, что тесты проходят**

Run: `swift test --filter ManualFixTests`
Expected: PASS, 10 тестов. Если какой-то ожидаемый результат конверсии не совпал, проверь таблицу в `TextConverter` и исправь **ожидание теста** только для того случая, где таблица соответствует физической раскладке (см. `TextConverterTests`). Код не подгоняй.

- [ ] **Step 5: Коммит**

```bash
git add Sources/LatCyr/ManualFix.swift Tests/LatCyrTests/ManualFixTests.swift
git commit -m "feat: add ManualFix.plan for fix-and-remember

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Выделение и предыдущее слово в `TextFieldController`

**Files:**
- Modify: `Sources/LatCyr/TextFieldController.swift` (после `extendAnchor`, ~строка 214)
- Test: `Tests/LatCyrTests/ExtendRangeTests.swift` (добавить в конец класса)

**Interfaces:**
- Consumes: `extendRange(_:backwardOver:in:variant:)`, `text(of:)`, `selectedRange(of:)`, `focusedTextElement()`, `isOwnApp`, `isSecure` (существующие).
- Produces:
  - `func selectionAnchor() -> (anchor: WordAnchor, text: String)?` — непустое выделение в редактируемом, не защищённом, не своём поле;
  - `func previousWordAnchor(before anchor: WordAnchor, word: String, variant: TextConverter.RussianKeyboardVariant) -> WordAnchor?` — слово `word` прямо перед `anchor` через ровно один пробел, с границей перед ним.

- [ ] **Step 1: Написать тесты сценария «предыдущее слово»** (в конец `ExtendRangeTests`)

```swift
    // MARK: - Previous word (fix-and-remember)

    /// previousWordAnchor asks extendRange for exactly one word before the
    /// corrected span: "ubarf надо" with the span on "надо".
    func testPreviousWordBeforeCorrectedSpan() {
        let text = "ubarf надо"
        let units = utf16(text)
        let spanStart = "ubarf ".utf16.count
        let start = controller.extendRange(spanStart..<units.count, backwardOver: ["ubarf"], in: units, variant: .pc)
        XCTAssertEqual(start, 0)
    }

    func testPreviousWordAfterEarlierText() {
        let text = "Ну и ubarf надо"
        let units = utf16(text)
        let spanStart = "Ну и ubarf ".utf16.count
        let start = controller.extendRange(spanStart..<units.count, backwardOver: ["ubarf"], in: units, variant: .pc)
        XCTAssertEqual(start, "Ну и ".utf16.count)
    }

    func testPreviousWordRejectedAcrossDoubleSpace() {
        let text = "ubarf  надо"
        let units = utf16(text)
        let spanStart = "ubarf  ".utf16.count
        XCTAssertNil(controller.extendRange(spanStart..<units.count, backwardOver: ["ubarf"], in: units, variant: .pc))
    }

    func testPreviousWordRejectedAcrossComma() {
        let text = "ubarf, надо"
        let units = utf16(text)
        let spanStart = "ubarf, ".utf16.count
        XCTAssertNil(controller.extendRange(spanStart..<units.count, backwardOver: ["ubarf"], in: units, variant: .pc))
    }
```

- [ ] **Step 2: Прогнать — тесты проходят сразу**

Run: `swift test --filter ExtendRangeTests`
Expected: PASS. Это не TDD-цикл, а фиксация контракта: `extendRange` уже делает то, что нужно, и тесты закрепляют использование, на которое опирается новая обёртка. Если какой-то тест упал — **остановись**: значит, у `extendRange` другой контракт, и шаг 3 нужно пересмотреть.

- [ ] **Step 3: Добавить обёртки** — сразу после `extendAnchor(_:backwardOver:variant:)`

```swift
    /// The non-empty selection in the focused field, with its range. nil for
    /// no selection, a secure or own field, or an app whose visible text is
    /// not a real AX value (terminals, hybrid apps).
    func selectionAnchor() -> (anchor: WordAnchor, text: String)? {
        guard let element = focusedTextElement(), !isOwnApp(element), !isSecure(element),
              let text = text(of: element), let selection = selectedRange(of: element),
              selection.length > 0 else { return nil }
        let utf16 = Array(text.utf16)
        let range = selection.location..<(selection.location + selection.length)
        guard range.lowerBound >= 0, range.upperBound <= utf16.count else { return nil }
        let selected = String(utf16CodeUnits: Array(utf16[range]), count: range.count)
        return (WordAnchor(element: element, range: range), selected)
    }

    /// `word` sitting right before `anchor`, separated by exactly one space
    /// and preceded by a word boundary — the word fix-and-remember targets
    /// when nothing is selected. Same matching rules as the carried chain,
    /// so it reuses extendRange.
    func previousWordAnchor(
        before anchor: WordAnchor, word: String, variant: TextConverter.RussianKeyboardVariant
    ) -> WordAnchor? {
        guard let text = text(of: anchor.element) else { return nil }
        let utf16 = Array(text.utf16)
        guard anchor.range.upperBound <= utf16.count,
              let start = extendRange(anchor.range, backwardOver: [word], in: utf16, variant: variant) else { return nil }
        // extendRange returns the start of the word; it ends one space
        // before the anchor.
        return WordAnchor(element: anchor.element, range: start..<(anchor.range.lowerBound - 1))
    }
```

- [ ] **Step 4: Сборка и тесты**

Run: `swift build && swift test`
Expected: сборка без ошибок, все тесты PASS.

- [ ] **Step 5: Коммит**

```bash
git add Sources/LatCyr/TextFieldController.swift Tests/LatCyrTests/ExtendRangeTests.swift
git commit -m "feat: AX helpers for the selection and the word before a correction

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `InputMonitor` — `flagsChanged`, предыдущее слово и кандидат

**Files:**
- Create: `Sources/LatCyr/PendingFix.swift`
- Modify: `Sources/LatCyr/InputMonitor.swift`

**Interfaces:**
- Consumes: `DoubleShiftDetector` (Task 1), `TextFieldController.previousWordAnchor` (Task 3).
- Produces:
  - `struct PreviousWord { let text: String; let layoutIsRussian: Bool; let variant: TextConverter.RussianKeyboardVariant }`
  - `enum PendingFix { case anchored(anchor: TextFieldController.WordAnchor, word: String, variant: TextConverter.RussianKeyboardVariant); case keystroke(word: String, tail: String, keyDownCount: Int, variant: TextConverter.RussianKeyboardVariant) }`
  - в `InputMonitor`: `private(set) var pendingFix: PendingFix?`, `private(set) var keyDownCount: Int`, `var onDoubleShift: (() -> Void)?` (вызывается на главной очереди; подключается в Task 5).

Здесь нет юнит-тестов: `InputMonitor` — обёртка над tap, проверяется вручную (см. CLAUDE.md). Критерий задачи — сборка, все тесты зелёные и строки `debug` в логе при ручной проверке шага 7.

- [ ] **Step 1: Создать `Sources/LatCyr/PendingFix.swift`**

```swift
import Foundation

/// The last completed word that LatCyr left as typed, remembered at the
/// space after it. A correction of the next word turns it into a
/// PendingFix candidate.
struct PreviousWord {
    let text: String
    let layoutIsRussian: Bool
    let variant: TextConverter.RussianKeyboardVariant
}

/// What double Shift fixes when nothing is selected: the word right before
/// the latest automatic correction.
enum PendingFix {
    /// AX apps: the word's position, re-verified against the live text
    /// before any write.
    case anchored(anchor: TextFieldController.WordAnchor, word: String, variant: TextConverter.RussianKeyboardVariant)
    /// Hybrid apps and terminals: the word and the exact text after it on
    /// screen (space, corrected span, boundary). Valid only while no key has
    /// been pressed since — `keyDownCount` is InputMonitor's count at the
    /// correction.
    case keystroke(word: String, tail: String, keyDownCount: Int, variant: TextConverter.RussianKeyboardVariant)
}
```

- [ ] **Step 2: Состояние и маска tap в `InputMonitor`**

После `private var currentWordIsFragment = false` (строка 53) добавить:

```swift
    /// The word before the current one, if LatCyr left it as typed and it
    /// ended at a single space. Broken by everything that breaks the carry
    /// chain. See PreviousWord.
    private var previousWord: PreviousWord?
    /// Candidate for fix-and-remember with nothing selected. Replaced by
    /// every successful automatic correction; cleared on app switch.
    private(set) var pendingFix: PendingFix?
    /// Genuine (non-synthetic) keyDowns seen. A keystroke PendingFix is
    /// valid only while this hasn't moved since the correction.
    private(set) var keyDownCount = 0
    private var doubleShift = DoubleShiftDetector()
    /// Called on the main queue when a double Shift is recognised.
    var onDoubleShift: (() -> Void)?

    private static let leftShiftKeyCode: CGKeyCode = 56
    private static let rightShiftKeyCode: CGKeyCode = 60
```

В `start()` заменить строку маски:

```swift
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
```

- [ ] **Step 3: Единая точка разрыва цепочки**

Добавить метод в `// MARK: - Event handling` перед `handle`:

```swift
    /// Everything that breaks the carry chain also breaks "the word right
    /// before": both describe text immediately behind the cursor.
    private func breakChain() {
        carry.reset()
        previousWord = nil
    }
```

Заменить `carry.reset()` на `breakChain()` в этих местах (номера строк — до правок, ищи по окружающему коду):
- наблюдатель активации приложения (≈115), и дополнительно добавить там строку `self.pendingFix = nil`;
- `stop()` (≈139), и дополнительно `pendingFix = nil`;
- ветка шортката Cmd/Ctrl (≈216);
- Backspace за начало слова (≈227);
- «no character for keyCode» (≈244);
- второй разделитель (≈275);
- пароль в терминале (≈281);
- не-буква, не-граница (≈325);
- успех проактивной правки в `performProactiveFix` (≈550);
- `performLeadingCharCheck` (≈582).

**Не** заменять в ветке `wrong` (≈284) и в ветке `else` (≈311): их правят шаги 5 и 6.

- [ ] **Step 4: `flagsChanged` и счётчик клавиш в `handle`**

Сразу после блока `tapDisabledByTimeout` и перед `guard type == .keyDown` вставить:

```swift
        if type == .flagsChanged {
            guard event.getIntegerValueField(.eventSourceUserData) != KeystrokeSimulator.eventMarker else { return false }
            handleFlagsChanged(event)
            return false
        }
```

Сразу после строки `guard event.getIntegerValueField(.eventSourceUserData) != KeystrokeSimulator.eventMarker else { return false }` (проверка метки для keyDown) вставить:

```swift
        keyDownCount += 1
        _ = doubleShift.feed(.otherKey, at: Self.seconds(event))
```

Добавить методы рядом с `handle`:

```swift
    /// Shift transitions go to the double-Shift detector; any other modifier
    /// breaks a pending pair. Never touches the word buffer or the chain —
    /// modifiers don't type anything.
    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let input: DoubleShiftDetector.Input
        if keyCode == Self.leftShiftKeyCode || keyCode == Self.rightShiftKeyCode,
           flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]).isEmpty {
            input = flags.contains(.maskShift) ? .shiftDown : .shiftUp
        } else {
            input = .otherKey
        }
        guard doubleShift.feed(input, at: Self.seconds(event)) else { return }
        Log.debug("double shift recognised")
        DispatchQueue.main.async { [weak self] in self?.onDoubleShift?() }
    }

    /// CGEvent timestamps are nanoseconds since boot.
    private static func seconds(_ event: CGEvent) -> TimeInterval {
        TimeInterval(event.timestamp) / 1_000_000_000
    }
```

- [ ] **Step 5: Запоминание предыдущего слова (ветка `else` границы)**

Ветку (≈310–312)

```swift
            } else {
                carry.reset()
            }
```

заменить на:

```swift
            } else {
                carry.reset()
                // A word LatCyr left alone, ended by a single space: the
                // candidate for fix-and-remember if the next word gets
                // corrected. A fragment is the tail of an on-screen token,
                // not a word of its own.
                previousWord = (char == " " && !currentWord.isEmpty && !currentWordIsFragment)
                    ? PreviousWord(text: currentWord, layoutIsRussian: currentLayoutIsRussian, variant: currentRussianVariant)
                    : nil
            }
```

В ветке подхвата (`carry.append(...)`, ≈309) `previousWord` не трогается: слово перед цепочкой остаётся кандидатом.

- [ ] **Step 6: Передать предыдущее слово в коррекцию (ветка `wrong`)**

Ветку `} else if wrong {` (≈282–297) заменить на:

```swift
            } else if wrong {
                let carried = carry.carried(layoutIsRussian: currentLayoutIsRussian, variant: currentRussianVariant)
                // Only a word typed in the same layout and variant can be
                // the one LatCyr missed right before this correction.
                let before = previousWord.flatMap {
                    $0.layoutIsRussian == currentLayoutIsRussian && $0.variant == currentRussianVariant ? $0 : nil
                }
                breakChain()
                if char.isNewline || char == "\t" {
                    let word = currentWord
                    currentWord = ""
                    // A genuine boundary character was processed; the early
                    // return here is only about correcting synchronously, not
                    // about skipping the boundary bookkeeping.
                    currentWordIsFragment = false
                    return applyCorrectionNow(
                        word: word, carried: carried, wasRussian: currentLayoutIsRussian,
                        variant: currentRussianVariant, keyCode: keyCode, previous: before
                    )
                }
                scheduleRetroactiveCheck(word: currentWord, carried: carried, wasRussian: currentLayoutIsRussian, variant: currentRussianVariant, boundary: char, previous: before)
```

- [ ] **Step 7: Протянуть `previous` через планирование**

`scheduleRetroactiveCheck`: добавить параметр `previous: PreviousWord?` и после `let resolved = resolveCarry(...)` вычислить якорь:

```swift
        let previousAnchor = previous.flatMap { prev in
            resolved.anchor.flatMap { textFieldController.previousWordAnchor(before: $0, word: prev.text, variant: variant) }
        }
        let keyDownsAtBoundary = keyDownCount
```

и в вызов `applyCorrection(...)` внутри `asyncAfter` добавить аргументы `previous: previous, previousAnchor: previousAnchor, keyDownsAtBoundary: keyDownsAtBoundary`.

`applyCorrectionNow`: добавить параметр `previous: PreviousWord?`, после `let resolved = ...` то же вычисление `previousAnchor`, и в вызов `applyCorrection(...)` добавить `previous: previous, previousAnchor: previousAnchor, keyDownsAtBoundary: keyDownCount`.

`scheduleProactiveCheck`: захватить `let previous = previousWord.flatMap { $0.layoutIsRussian == currentLayoutIsRussian && $0.variant == currentRussianVariant ? $0 : nil }` и передать в `performProactiveFix(word:wasRussian:variant:previous:)`.

`performProactiveFix`: добавить параметр `previous: PreviousWord?`. Вычисление `carried` (≈539–541) заменить на:

```swift
        // The anchor serves two checks: the carried chain, and the word
        // right before the span for fix-and-remember.
        let prefixAnchor = (pending.isEmpty && previous == nil) ? nil : captureAnchor(matching: word, variant: variant).anchor
        let resolved = resolveCarry(pending, anchor: prefixAnchor, variant: variant)
        let carried = pending.isEmpty ? [] : resolved.carried
        let previousAnchor = previous.flatMap { prev in
            resolved.anchor.flatMap { textFieldController.previousWordAnchor(before: $0, word: prev.text, variant: variant) }
        }
        if applyCorrection(word: word, carried: carried, wasRussian: wasRussian, variant: variant, replacePrefix: true,
                           previous: previous, previousAnchor: previousAnchor, keyDownsAtBoundary: keyDownCount) {
```

(строка `if applyCorrection(word: word, carried: carried, ... replacePrefix: true) {` заменяется последней строкой выше; тело `if` без изменений).

- [ ] **Step 8: Создание кандидата в `applyCorrection`**

Сигнатуру дополнить тремя параметрами со значениями по умолчанию:

```swift
        anchorFailure: TextFieldController.AnchorFailure? = nil,
        previous: PreviousWord? = nil,
        previousAnchor: TextFieldController.WordAnchor? = nil,
        keyDownsAtBoundary: Int = 0
    ) -> Bool {
```

В ветке успешного ретрая (`if axReplaced {` внутри блока `wordAnchor`, ≈647) перед `switchLayout` добавить:

```swift
                recordPendingFix(previous: previous, anchor: previousAnchor)
```

В ветке `if axReplaced {` (≈657) перед `switchLayout` добавить ту же строку:

```swift
            recordPendingFix(previous: previous, anchor: previousAnchor)
```

В ветке успеха нажатиями — перед `Log.info("corrected via keystroke ...")` (≈700) добавить:

```swift
        // Screen after the previous word is now exactly: space, the corrected
        // span, the boundary — but only if no key landed since the boundary
        // (correctionDelay is 50 ms of the user still typing). Enter/Tab and
        // the proactive path have no visible boundary: no candidate.
        if let previous, let boundary, keyDownCount == keyDownsAtBoundary {
            pendingFix = .keystroke(
                word: previous.text, tail: " " + converted + String(boundary),
                keyDownCount: keyDownCount, variant: previous.variant
            )
        } else {
            pendingFix = nil
        }
```

Добавить метод рядом с `logNotApplied`:

```swift
    /// After an AX correction: the word before it becomes the candidate, or
    /// the old candidate is dropped — a newer correction supersedes it.
    private func recordPendingFix(previous: PreviousWord?, anchor: TextFieldController.WordAnchor?) {
        if let previous, let anchor {
            pendingFix = .anchored(anchor: anchor, word: previous.text, variant: previous.variant)
            Log.debug("pending fix recorded (ax): \(Sensitive(previous.text))")
        } else {
            pendingFix = nil
        }
    }
```

- [ ] **Step 9: Сборка и тесты**

Run: `swift build && swift test`
Expected: сборка без ошибок и предупреждений о неиспользуемых значениях, все тесты PASS.

- [ ] **Step 10: Ручная проверка детектора**

```bash
./scripts/package-app.sh
```

Поставить `dist/LatCyr.app` вместо `/Applications/LatCyr.app` (закрыть LatCyr через меню «Выход», заменить, открыть), в меню «Логирование» выбрать «Отладка». В TextEdit: быстро дважды нажать Shift → в `~/Library/Logs/LatCyr/latcyr.log` строка `double shift recognised`. Набрать `ID` с Shift — строки нет. Набрать `ubarf yflj ` → строка `pending fix recorded (ax): [5 lat]`.

- [ ] **Step 11: Коммит**

```bash
git add Sources/LatCyr/PendingFix.swift Sources/LatCyr/InputMonitor.swift
git commit -m "feat: recognise double Shift and remember the word before a correction

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `ManualFixer` и запуск по ⇧⇧

**Files:**
- Create: `Sources/LatCyr/ManualFixer.swift`
- Modify: `Sources/LatCyr/InputMonitor.swift`

**Interfaces:**
- Consumes: `ManualFix.plan` (Task 2), `TextFieldController.selectionAnchor`, `replaceAnchoredWord` (Task 3 / существующий), `PendingFix` и `InputMonitor.onDoubleShift`, `pendingFix`, `keyDownCount` (Task 4), `KeystrokeSimulator.correct`, `ClipboardReader.copySelection`, `ExceptionStore.add`.
- Produces:
  - `final class ManualFixer` с `enum Outcome { case fixed(exception: String), nothingToFix, invalidWord, refused(String), failed(String) }` и `func run(pending: PendingFix?, keyDownCount: Int, completion: @escaping (Outcome) -> Void)`;
  - в `InputMonitor`: `let clipboardReader = ClipboardReader()`, `func fixAndRemember(completion: @escaping (ManualFixer.Outcome) -> Void)`.

- [ ] **Step 1: Создать `Sources/LatCyr/ManualFixer.swift`**

```swift
import AppKit

/// Performs fix-and-remember: converts the selected word, or the word right
/// before the latest automatic correction, and adds the corrected form to
/// the exceptions. A thin wrapper over AX, keystrokes and the clipboard —
/// the decisions are ManualFix.plan's and PendingFix's; verified by hand.
final class ManualFixer {
    enum Outcome {
        case fixed(exception: String)
        case nothingToFix
        case invalidWord
        case refused(String)
        case failed(String)
    }

    private let textFieldController: TextFieldController
    private let keystrokeSimulator: KeystrokeSimulator
    private let clipboardReader: ClipboardReader
    private let exceptionStore: ExceptionStore
    private let layoutManager: LayoutManager

    init(
        textFieldController: TextFieldController, keystrokeSimulator: KeystrokeSimulator,
        clipboardReader: ClipboardReader, exceptionStore: ExceptionStore, layoutManager: LayoutManager
    ) {
        self.textFieldController = textFieldController
        self.keystrokeSimulator = keystrokeSimulator
        self.clipboardReader = clipboardReader
        self.exceptionStore = exceptionStore
        self.layoutManager = layoutManager
    }

    /// Main queue only. `pending` and `keyDownCount` are InputMonitor's at
    /// the moment of the request. The password check is the caller's.
    func run(pending: PendingFix?, keyDownCount: Int, completion: @escaping (Outcome) -> Void) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            return completion(.refused("own app"))
        }
        if textFieldController.isFocusedElementSecure() {
            return completion(.refused("secure field"))
        }
        let isTerminal = keystrokeSimulator.isTerminalFrontmost
        let isHybrid = keystrokeSimulator.isHybridFrontmost
        guard isTerminal || isHybrid else {
            return completion(runAX(pending: pending))
        }
        // Keystroke apps: the candidate first — see the plan's note on Cmd+C
        // copying a whole line when nothing is selected.
        if case let .keystroke(word, tail, count, variant) = pending, count == keyDownCount {
            return completion(retype(word: word, tail: tail, variant: variant))
        }
        guard isHybrid else { return completion(.nothingToFix) }
        clipboardReader.copySelection { [weak self] copied in
            guard let self else { return }
            guard let copied, !copied.contains(where: \.isNewline) else { return completion(.nothingToFix) }
            guard let plan = ManualFix.plan(for: copied, variant: self.layoutManager.currentRussianVariant) else {
                return completion(.invalidWord)
            }
            // Typing over a selection replaces it — nothing to delete.
            guard self.keystrokeSimulator.correct(deleting: 0, typing: plan.replacement) else {
                return completion(.failed("keystrokes could not be posted"))
            }
            completion(self.remember(plan, path: "selection-hybrid"))
        }
    }

    // MARK: - Private

    private func runAX(pending: PendingFix?) -> Outcome {
        if let selection = textFieldController.selectionAnchor() {
            guard let plan = ManualFix.plan(for: selection.text, variant: layoutManager.currentRussianVariant) else {
                return .invalidWord
            }
            guard textFieldController.replaceAnchoredWord(selection.anchor, word: selection.text, with: plan.replacement) else {
                return .failed("AX replace rejected or not applied")
            }
            return remember(plan, path: "selection-ax")
        }
        guard case let .anchored(anchor, word, variant) = pending else { return .nothingToFix }
        guard let plan = ManualFix.plan(for: word, variant: variant) else { return .invalidWord }
        // replaceAnchoredWord re-reads the text at the anchor and refuses if
        // it no longer holds `word` — before any write.
        guard textFieldController.replaceAnchoredWord(anchor, word: word, with: plan.replacement) else {
            return .failed("text at the remembered position changed")
        }
        return remember(plan, path: "pending-ax")
    }

    private func retype(word: String, tail: String, variant: TextConverter.RussianKeyboardVariant) -> Outcome {
        guard let plan = ManualFix.plan(for: word, variant: variant) else { return .invalidWord }
        guard keystrokeSimulator.correct(deleting: word.count + tail.count, typing: plan.replacement + tail) else {
            return .failed("keystroke fallback refused or failed")
        }
        return remember(plan, path: "pending-keystroke")
    }

    private func remember(_ plan: ManualFix.Plan, path: String) -> Outcome {
        exceptionStore.add(plan.exception)
        Log.info("fix-and-remember (\(path)): -> \(Sensitive(plan.replacement)), exception added")
        return .fixed(exception: plan.exception)
    }
}
```

- [ ] **Step 2: Подключить в `InputMonitor`**

Рядом с `let hybridAppStore = HybridAppStore()` добавить:

```swift
    /// One instance for the whole app: its re-entry guard only works per
    /// instance. AppDelegate's "add selection to exceptions" uses it too.
    let clipboardReader = ClipboardReader()
    private lazy var manualFixer = ManualFixer(
        textFieldController: textFieldController, keystrokeSimulator: keystrokeSimulator,
        clipboardReader: clipboardReader, exceptionStore: exceptionStore, layoutManager: layoutManager
    )
```

В `init()` после `hybridAppStore.load()` добавить:

```swift
        onDoubleShift = { [weak self] in
            self?.fixAndRemember { outcome in
                if case .fixed = outcome { return }
                NSSound.beep()
            }
        }
```

Добавить публичный метод (в `// MARK: - Correction`, перед `scheduleProactiveCheck`):

```swift
    /// Fix-and-remember, from double Shift or the menu. Main queue only.
    func fixAndRemember(completion: @escaping (ManualFixer.Outcome) -> Void) {
        // A terminal waiting for a password: whatever we'd retype could be it.
        guard !terminalAwaitsPassword() else {
            Log.info("fix-and-remember skipped: a terminal awaits a password")
            return completion(.refused("password prompt"))
        }
        manualFixer.run(pending: pendingFix, keyDownCount: keyDownCount) { [weak self] outcome in
            switch outcome {
            case .fixed:
                self?.pendingFix = nil
            case .nothingToFix:
                Log.info("fix-and-remember: nothing selected and no candidate")
            case .invalidWord:
                Log.info("fix-and-remember: not one word in one alphabet")
            case .refused(let reason), .failed(let reason):
                Log.info("fix-and-remember not applied: \(reason)")
            }
            completion(outcome)
        }
    }
```

`pendingFix` объявлен `private(set)`, поэтому присвоение `self?.pendingFix = nil` внутри класса компилируется.

- [ ] **Step 3: Сборка и тесты**

Run: `swift build && swift test`
Expected: сборка без ошибок, все тесты PASS.

- [ ] **Step 4: Ручная проверка**

Упаковать и поставить, как в Task 4 шаг 10. Проверить:
1. TextEdit: `ubarf yflj ` → «ubarf надо» → ⇧⇧ → «гифка надо». В `~/Library/Application Support/LatCyr/exceptions.txt` появилась строка `гифка`.
2. TextEdit: двойной клик по слову `ghbdtn` в середине текста → ⇧⇧ → «привет».
3. TextEdit без выделения и без недавнего исправления: ⇧⇧ → системный звук, текст не меняется.
4. Claude Desktop, терминальная панель: `пше ыефегы` (если `ыефегы` исправилось в `status`) → сразу ⇧⇧ → `git status`. Если после исправления была нажата любая клавиша — звук и без изменений.
5. Поле пароля: ⇧⇧ ничего не меняет.

- [ ] **Step 5: Коммит**

```bash
git add Sources/LatCyr/ManualFixer.swift Sources/LatCyr/InputMonitor.swift
git commit -m "feat: fix-and-remember on double Shift

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Пункт меню и общий `ClipboardReader`

**Files:**
- Modify: `Sources/LatCyr/AppDelegate.swift`

**Interfaces:**
- Consumes: `InputMonitor.fixAndRemember(completion:)`, `InputMonitor.clipboardReader` (Task 5).

- [ ] **Step 1: Общий `ClipboardReader`**

Удалить строку `private let clipboardReader = ClipboardReader()` (строка 9). В `addSelectedWordToExceptions` заменить `clipboardReader.copySelection` на `inputMonitor.clipboardReader.copySelection`.

- [ ] **Step 2: Пункт меню** — в `buildMenu()` перед `addExceptionItem`

```swift
        let fixItem = NSMenuItem(
            title: "Исправить выделенное и запомнить (⇧⇧)",
            action: #selector(fixAndRemember),
            keyEquivalent: ""
        )
        fixItem.target = self
        menu.addItem(fixItem)
```

- [ ] **Step 3: Действие** — после `addSelectedWordToExceptions`

```swift
    @objc private func fixAndRemember() {
        inputMonitor.fixAndRemember { [weak self] outcome in
            switch outcome {
            case .fixed(let exception):
                self?.showAlert(message: "Исправлено и запомнено: \(exception)")
            case .nothingToFix:
                self?.showAlert(message: "Выделите слово, набранное не в той раскладке.")
            case .invalidWord:
                self?.showAlert(message: "Выделите одно слово на одном языке — русском или английском.")
            case .refused, .failed:
                self?.showAlert(message: "Не удалось исправить здесь. В терминалах и некоторых приложениях это не поддерживается.")
            }
        }
    }
```

- [ ] **Step 4: Сборка и тесты**

Run: `swift build && swift test`
Expected: сборка без ошибок, все тесты PASS.

- [ ] **Step 5: Ручная проверка**

Упаковать и поставить. В TextEdit выделить `ubarf` → меню «Исправить выделенное и запомнить (⇧⇧)» → «гифка» и окно «Исправлено и запомнено: гифка». «Добавить выделенное в исключения» по-прежнему работает, включая Claude Desktop (через буфер обмена).

- [ ] **Step 6: Коммит**

```bash
git add Sources/LatCyr/AppDelegate.swift
git commit -m "feat: menu item for fix-and-remember

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Документация

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/superpowers/specs/2026-10-20-fix-and-remember-design.md`

- [ ] **Step 1: Спека — внести три уточнения из раздела «Уточнения к спеке» этого плана**
  - §3 «Кандидат»: вместо `previousWordRange` — `TextFieldController.previousWordAnchor`, которая вызывает `extendRange` с одним словом; тесты — в `ExtendRangeTests`.
  - §4 «ManualFixer», шаги 3–4: в гибридных приложениях и терминалах кандидат проверяется раньше выделения; скопированный текст с переводом строки отклоняется (VS Code без выделения копирует строку).
  - §4: один `ClipboardReader` на приложение, им владеет `InputMonitor`.
  - Раздел «Тесты»: `PreviousWordRangeTests` → сценарии в `ExtendRangeTests`.

- [ ] **Step 2: CLAUDE.md**
  - В «Два пути срабатывания» после пункта 4 добавить пункт 5: «**Исправить и запомнить (⇧⇧ или меню)** — ручной путь: `DoubleShiftDetector` (чистый, срабатывает на втором отпускании Shift: оба нажатия и пауза ≤ 0,3 с, без других клавиш между ними) → `InputMonitor.fixAndRemember` → `ManualFixer`. Цель — выделение или `PendingFix` (слово прямо перед последним автоисправлением через ровно один пробел; в AX — диапазон, перепроверяемый перед записью, через `previousWordAnchor`/`extendRange`; в гибридных и терминалах — слово и точный хвост, годны только до следующего `keyDown`). `ManualFix.plan` выбирает направление по алфавиту и проверяет результат, а не источник (латинская запись русского слова законно содержит `;` и `,`). В исключения уходит исправленная форма. Раскладка не переключается. Спека — `docs/superpowers/specs/2026-10-20-fix-and-remember-design.md`.»
  - В «Ключевые решения» добавить пункт: «**Tap слушает и `flagsChanged`:** только ради ⇧⇧. `handleFlagsChanged` не трогает буфер слова и цепочку; синтетические события с меткой игнорируются и здесь. Предыдущее слово (`previousWord`) рвётся тем же, что и цепочка (`breakChain()`).»
  - В «Тесты» добавить: «`DoubleShiftDetectorTests` — срабатывание на втором отпускании, медленные нажатия и паузы, Shift+буква, тройной Shift. `ManualFixTests` — оба направления и варианта, пунктуационные клавиши, регистр, отказы. `ExtendRangeTests` — сценарий «предыдущее слово».»

- [ ] **Step 3: Тесты**

Run: `swift test`
Expected: PASS.

- [ ] **Step 4: Коммит**

```bash
git add CLAUDE.md docs/superpowers/specs/2026-10-20-fix-and-remember-design.md
git commit -m "docs: document fix-and-remember

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Финальная ручная проверка (после всех задач)

Список из спеки, раздел «Тесты → Вручную»: TextEdit, Safari, Mail (выделение и кандидат); Claude Desktop (чат и терминал); Terminal.app (сразу после исправления и после Enter); ложные срабатывания на `ID`, `URL`, «ООО», Shift+стрелки; поле пароля; повторный набор после ⇧⇧ исправляется сам.
