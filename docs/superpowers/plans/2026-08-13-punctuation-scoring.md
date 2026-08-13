# Слова с пунктуацией внутри и коррекция по Enter — План реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Слово с пунктуацией внутри (`amazon.de`, набранное в русской раскладке как `фьфящтюву`) детектируется и заменяется целиком, а коррекция по Enter успевает до того, как приложение обработает клавишу.

**Architecture:** Две независимые правки. Первая — в чистой функции `LanguageDetector.isWrongLayout`: перед скорингом выбрасываются позиции, где конверсия даёт пунктуацию; заменяемое слово при этом не меняется. Вторая — в `InputMonitor`: разделители `Enter`/`Tab` корректируются синхронно внутри callback'а event tap, минуя `correctionDelay`, плюс восстановление tap'а после отключения системой по таймауту.

**Tech Stack:** Swift Package (без Xcode), XCTest, CoreGraphics `CGEventTap`, Accessibility API.

**Спецификация:** `docs/superpowers/specs/2026-08-13-punctuation-scoring-design.md`

## Global Constraints

- Все комментарии в коде — на английском (текущий стиль репозитория).
- `LanguageDetector` и `TextConverter` остаются чистыми функциями без системных зависимостей.
- Режим event tap не меняется: `options: .listenOnly`, `place: .headInsertEventTap`.
- Синтетический Enter не отправляется никогда.
- Порядок `applyCorrection` «замена текста → переключение раскладки» не меняется.
- Пороги эвристики (`russianThreshold = 0.4`, `englishThreshold = 0.35`, `diffThreshold = 0.1`, `minWordLength = 3`, `runPenalty = 0.15`) не трогаются.
- Коммиты — conventional style (`feat:`, `fix:`, `docs:`).

---

## Task 1: Фильтрация пунктуации перед скорингом

**Files:**
- Modify: `Sources/LatCyr/LanguageDetector.swift:119-143` (`isWrongLayout`, добавление приватной функции)
- Modify: `CLAUDE.md` (раздел «Ключевые решения, которые легко сломать»)
- Test: `Tests/LatCyrTests/LanguageDetectorTests.swift`

**Interfaces:**
- Consumes: `TextConverter.toLatin(_:variant:)`, `TextConverter.toCyrillic(_:variant:)` — посимвольная конверсия 1:1, длина строки сохраняется.
- Produces: приватная `LanguageDetector.strippingPunctuation(_:_:) -> (original: String, converted: String)`. Публичная сигнатура `isWrongLayout(word:currentLayoutIsRussian:exceptions:variant:) -> Bool` не меняется.

- [ ] **Step 1: Написать падающий тест**

Добавить в `Tests/LatCyrTests/LanguageDetectorTests.swift` перед закрывающей скобкой класса:

```swift
    // A word whose conversion contains punctuation — a domain name — must be
    // scored on its letters alone. "фьфящтюву" is "amazon.de" typed under the
    // Russian layout: the "ю" comes from the "." key but is a Russian vowel
    // with its own frequency weight, and counting it puts russianScore at
    // 0.424 — just over the 0.4 threshold, so the whole correction was
    // dropped. Scored without it the word sits at 0.323 and is corrected in
    // full, dot included.
    func testDomainWithPunctuationDetected() {
        XCTAssertEqual(TextConverter.toLatin("фьфящтюву", variant: .pc), "amazon.de")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "фьфящтюву", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
    }
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

```bash
swift test --filter LanguageDetectorTests/testDomainWithPunctuationDetected
```

Ожидание: FAIL на второй строке — `XCTAssertTrue failed`. Первая строка (`toLatin`) должна пройти: она лишь фиксирует, что разбор слова верный.

- [ ] **Step 3: Реализовать фильтрацию**

В `Sources/LatCyr/LanguageDetector.swift` добавить приватную функцию в секцию `// MARK: - Decisions`, сразу перед `isWrongLayout`:

```swift
    /// Drop the positions where the *conversion* yields punctuation: those
    /// characters are separators that ended up inside the word (a domain's
    /// dot, typed as "ю" under the Russian layout), not letters of it. Left
    /// in, they skew both the vowel ratio and the frequency sum — enough to
    /// hold a genuine wrong-layout word above russianThreshold. Only scoring
    /// sees the filtered form; the word itself is still replaced whole,
    /// punctuation included.
    ///
    /// Filtering is deliberately one-sided, driven by `converted` and never
    /// by `original`. A character that is punctuation in the original but a
    /// letter in the conversion is a letter the user meant to type: with the
    /// English layout active, "," is the "б" key, while a Russian comma is
    /// typed as Shift+"/" and arrives as "?" — a plain word boundary that
    /// ends the buffer long before this runs.
    private static func strippingPunctuation(
        _ original: String, _ converted: String
    ) -> (original: String, converted: String) {
        let originalChars = Array(original)
        let convertedChars = Array(converted)
        // TextConverter maps character-for-character, so the indices line up.
        // If that ever stops being true, skip filtering rather than misalign.
        guard originalChars.count == convertedChars.count else { return (original, converted) }

        var keptOriginal = ""
        var keptConverted = ""
        for (o, c) in zip(originalChars, convertedChars) where !(c.isPunctuation || c.isSymbol) {
            keptOriginal.append(o)
            keptConverted.append(c)
        }
        return (keptOriginal, keptConverted)
    }
```

Затем в `isWrongLayout` заменить блок скоринга. Было:

```swift
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
```

Стало:

```swift
        if exceptions.contains(converted) { return true }

        let scored = strippingPunctuation(lower, converted)

        if currentLayoutIsRussian {
            let russian = russianScore(scored.original)
            let english = englishScore(scored.converted)
            return english > englishThreshold && russian < russianThreshold
                && english - russian > diffThreshold
        } else {
            let english = englishScore(scored.original)
            let russian = russianScore(scored.converted)
            return russian > russianThreshold && english < englishThreshold
                && russian - english > diffThreshold
        }
```

`minWordLength`, `allSatisfy` и обе проверки `exceptions` остаются выше и работают с полным словом — их не трогать.

- [ ] **Step 4: Запустить тест и убедиться, что он проходит**

```bash
swift test --filter LanguageDetectorTests/testDomainWithPunctuationDetected
```

Ожидание: PASS.

- [ ] **Step 5: Добавить регрессионные тесты**

Добавить в `Tests/LatCyrTests/LanguageDetectorTests.swift` рядом с тестом из шага 1:

```swift
    // Domains that already scored correctly must keep doing so: filtering
    // shortens the scored word, and a shorter word must not drift back over
    // a threshold.
    func testDomainsThatAlreadyWorkedStillDetected() {
        XCTAssertEqual(TextConverter.toLatin("пщщпдуюсщь", variant: .pc), "google.com")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "пщщпдуюсщь", currentLayoutIsRussian: true, exceptions: [], variant: .pc))

        XCTAssertEqual(TextConverter.toLatin("еюьу", variant: .pc), "t.me")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "еюьу", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
    }

    // The mirror case: a Cyrillic letter that merely *converts* to punctuation
    // is still a real letter of a correctly typed Russian word. Filtering must
    // not turn any of these into a false positive.
    func testCorrectRussianWordsWhoseConversionHasPunctuationNotTouched() {
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "пою", currentLayoutIsRussian: true, exceptions: [], variant: .pc))   // gj.
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "мою", currentLayoutIsRussian: true, exceptions: [], variant: .pc))   // vj.
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "съел", currentLayoutIsRussian: true, exceptions: [], variant: .pc))  // c]tk
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "т.е.", currentLayoutIsRussian: true, exceptions: [], variant: .pc))  // n/t/
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "т.к.", currentLayoutIsRussian: true, exceptions: [], variant: .pc))  // n/r/
    }

    // "ё" sits on a different physical key in each Russian variant ("`" under
    // .pc, "\" under .apple), but both convert to punctuation, so both must be
    // filtered out of scoring — and "объём" stays untouched either way.
    func testPunctuationFilteringHoldsForBothVariants() {
        XCTAssertEqual(TextConverter.toLatin("объём", variant: .pc), "j,]`v")
        XCTAssertEqual(TextConverter.toLatin("объём", variant: .apple), "j,]\\v")
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "объём", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "объём", currentLayoutIsRussian: true, exceptions: [], variant: .apple))
    }

    // Filtering is driven by the conversion, never by the original: under the
    // English layout "," and "]" are the "б" and "ъ" keys, so these words must
    // behave exactly as they did before.
    func testPunctuationInOriginalOnlyStillDetected() {
        XCTAssertEqual(TextConverter.toCyrillic("j,]trn", variant: .pc), "объект")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "j,]trn", currentLayoutIsRussian: false, exceptions: [], variant: .pc))

        XCTAssertEqual(TextConverter.toCyrillic("ghbdtn,", variant: .pc), "приветб")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ghbdtn,", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
    }
```

- [ ] **Step 6: Прогнать весь набор тестов**

```bash
swift test
```

Ожидание: PASS, все тесты. Особое внимание — старые тесты `testWordWithAmbiguousPunctuationLetter` (`ndj.` → «твою»), `testCorrectWordsNotTouched` («следующий» конвертируется в `cktle.obq`, и фильтр теперь выбрасывает «ю» из скоринга) и `testRussianVariantGatesAmbiguousLetterGuard`. Если что-то из них упало — это регрессия, а не повод править тест: возвращайся к шагу 3.

- [ ] **Step 7: Обновить CLAUDE.md**

В `CLAUDE.md`, раздел «Ключевые решения, которые легко сломать», добавить новый пункт сразу после пункта про «Слова-исключения (`ExceptionStore`)»:

```markdown
- **Скоринг игнорирует позиции, где конверсия даёт пунктуацию:** `LanguageDetector.isWrongLayout` перед вычислением скоров выбрасывает из обеих строк (оригинала и конверсии) те позиции, где символ в *конверсии* — `isPunctuation || isSymbol`. Без этого доменное имя не детектируется: `amazon.de`, набранное в русской раскладке как «фьфящтюву», даёт `russianScore` = 0.424 при пороге 0.4 — точку («ю» на клавише `.`) детектор считал обычной русской гласной с собственным частотным весом. Без неё скор падает до 0.323 и слово исправляется целиком, вместе с точкой. Разбивать такое слово по пунктуации на границе нельзя: «фьфящт» + «ву» дало бы `amazon` + неисправленное «ву» (короче `minWordLength`). Фильтрация односторонняя — по конверсии, не по оригиналу: символ, который пунктуация в оригинале, но буква в конверсии, — это буква, которую пользователь и хотел набрать (при английской раскладке `,` — клавиша «б», а русская запятая набирается Shift+`/` и приходит как `?`, обычная граница слова). `minWordLength`, проверка «только буквы и неоднозначные символы» и оба сравнения с `exceptions` работают с полным словом, до фильтрации; заменяется в тексте тоже полное слово.
```

- [ ] **Step 8: Коммит**

```bash
git add Sources/LatCyr/LanguageDetector.swift Tests/LatCyrTests/LanguageDetectorTests.swift CLAUDE.md
git commit -m "fix: score words without punctuation-converting positions"
```

---

## Task 2: Восстановление event tap после отключения системой

**Files:**
- Modify: `Sources/LatCyr/InputMonitor.swift:99-100` (начало `handle(event:type:)`)

**Interfaces:**
- Consumes: поле `eventTap: CFMachPort?` (`InputMonitor.swift:19`), уже существует.
- Produces: ничего нового наружу. Готовит почву для Task 3, где callback станет тяжелее.

Юнит-тестами не покрывается: `InputMonitor` — тонкая обёртка над `CGEventTap`, проверяется вручную (см. CLAUDE.md, раздел «Тесты»).

- [ ] **Step 1: Добавить обработку отключения tap'а**

В `Sources/LatCyr/InputMonitor.swift` в начало `handle(event:type:)`. Было:

```swift
    private func handle(event: CGEvent, type: CGEventType) {
        guard type == .keyDown else { return }
```

Стало:

```swift
    private func handle(event: CGEvent, type: CGEventType) {
        // The system disables a tap whose callback takes too long, and after
        // certain user input. Both types arrive here regardless of
        // eventsOfInterest, and without re-enabling the tap the app goes
        // silently dead until relaunch — the menu bar item still reads
        // "включено" while nothing is being monitored.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        guard type == .keyDown else { return }
```

- [ ] **Step 2: Собрать**

```bash
swift build
```

Ожидание: `Build complete!` без предупреждений.

- [ ] **Step 3: Проверить вручную, что монитор по-прежнему работает**

```bash
./scripts/package-app.sh
```

Затем `open dist/LatCyr.app`. Переупаковка меняет code hash и сбрасывает выданные разрешения — выдать `dist/LatCyr.app` заново Accessibility и Input Monitoring в System Settings → Privacy & Security, затем включить приложение через меню.

Проверка в TextEdit: набрать `ghbdtn ` → должно замениться на «привет » с переключением раскладки. Это подтверждает, что новая ветка не съедает обычные события.

- [ ] **Step 4: Коммит**

```bash
git add Sources/LatCyr/InputMonitor.swift
git commit -m "fix: re-enable the event tap after the system disables it"
```

---

## Task 3: Синхронная коррекция по Enter и Tab

> **Задача выполнена, но решение пересмотрено по итогам проверки на живой системе.** Синхронная AX-замена при `.listenOnly` гонку с доставкой Enter проигрывает — браузер получает событие параллельно с нашим callback. Итоговая реализация: активный tap с подавлением и повторной отправкой клавиши. Актуальное описание — раздел 4.3 спецификации; шаги ниже сохранены как история.

**Files:**
- Modify: `Sources/LatCyr/InputMonitor.swift:136-145` (ветка границы слова в `handle`), `Sources/LatCyr/InputMonitor.swift:166-178` (добавление метода рядом с `scheduleRetroactiveCheck`)
- Modify: `CLAUDE.md` (разделы «Два пути срабатывания (гибрид)» и «Ключевые решения, которые легко сломать»)

**Interfaces:**
- Consumes: `TextFieldController.captureWordAnchor(matching:variant:) -> WordAnchor?`, `applyCorrection(word:wasRussian:variant:replacePrefix:boundary:anchor:) -> Bool` (помечен `@discardableResult`), `LanguageDetector.isWrongLayout(...)` с фильтрацией из Task 1.
- Produces: приватная `InputMonitor.applyCorrectionNow(word:wasRussian:variant:boundary:)`. `applyCorrection` не меняется.

Юнит-тестами не покрывается — ручная проверка на шаге 4.

- [ ] **Step 1: Добавить синхронный путь коррекции**

В `Sources/LatCyr/InputMonitor.swift` добавить метод сразу после `scheduleRetroactiveCheck`:

```swift
    /// Correct right now, inside the event callback, skipping correctionDelay.
    /// That delay exists so the app can print the boundary character before we
    /// rewrite the text — but Enter and Tab print nothing, and they trigger an
    /// app action immediately (navigation, form submit, focus change). By the
    /// time a delayed correction fired, the browser has already sent the wrong
    /// request. The tap is installed at .headInsertEventTap, so the work done
    /// here lands before the app ever sees the key.
    ///
    /// AX-only in practice: applyCorrection's keystroke fallback already
    /// refuses Enter and Tab, so nothing is injected into a terminal — that
    /// case stays uncorrected, by design (see the spec's "Вне области").
    private func applyCorrectionNow(
        word: String, wasRussian: Bool,
        variant: TextConverter.RussianKeyboardVariant, boundary: Character
    ) {
        let anchor = textFieldController.captureWordAnchor(matching: word, variant: variant)
        applyCorrection(
            word: word, wasRussian: wasRussian, variant: variant,
            replacePrefix: false, boundary: boundary, anchor: anchor
        )
    }
```

- [ ] **Step 2: Направить Enter и Tab в синхронный путь**

В той же функции `handle`, ветка границы слова. Было:

```swift
        } else if isWordBoundary(char) {
            if currentWord.isEmpty {
                scheduleLeadingCharCheck(char)
            } else if LanguageDetector.isWrongLayout(word: currentWord, currentLayoutIsRussian: currentLayoutIsRussian, exceptions: exceptionStore.words, variant: currentRussianVariant) {
                scheduleRetroactiveCheck(word: currentWord, wasRussian: currentLayoutIsRussian, variant: currentRussianVariant, boundary: char)
            }
            currentWord = ""
        } else {
```

Стало:

```swift
        } else if isWordBoundary(char) {
            if currentWord.isEmpty {
                scheduleLeadingCharCheck(char)
            } else if LanguageDetector.isWrongLayout(word: currentWord, currentLayoutIsRussian: currentLayoutIsRussian, exceptions: exceptionStore.words, variant: currentRussianVariant) {
                if char.isNewline || char == "\t" {
                    applyCorrectionNow(word: currentWord, wasRussian: currentLayoutIsRussian, variant: currentRussianVariant, boundary: char)
                } else {
                    scheduleRetroactiveCheck(word: currentWord, wasRussian: currentLayoutIsRussian, variant: currentRussianVariant, boundary: char)
                }
            }
            currentWord = ""
        } else {
```

- [ ] **Step 3: Собрать и прогнать тесты**

```bash
swift build && swift test
```

Ожидание: `Build complete!` и PASS всех тестов. Тесты здесь ничего нового не покрывают — прогон нужен, чтобы убедиться, что правка в `InputMonitor` не задела `LanguageDetector`.

- [ ] **Step 4: Проверить вручную**

```bash
./scripts/package-app.sh
```

Затем `open dist/LatCyr.app`, заново выдать Accessibility и Input Monitoring для `dist/LatCyr.app` (переупаковка их сбрасывает) и включить приложение через меню.

Сценарии, все при активной **русской** раскладке:

1. **Адресная строка Safari:** набрать `фьфящтюву`, нажать Enter → переход на `amazon.de` с первого раза, без промежуточного поиска по «фьфящтюву».
2. **Адресная строка Chrome:** то же самое.
3. **Поле поиска на странице:** набрать `руддщ`, Enter → ищется `hello`.
4. **TextEdit:** набрать `руддщ`, Enter → «hello» и перевод строки; курсор на новой строке.
5. **TextEdit:** набрать `руддщ`, Tab → «hello» и табуляция.
6. **Мессенджер (Telegram или Slack):** набрать `руддщ`, Enter → отправлено ровно **одно** сообщение с текстом `hello`.
7. **Terminal.app:** набрать `руддщ`, Enter → коррекции нет, команда уходит как есть. Это ожидаемое поведение, не баг.
8. **Регрессия обычных разделителей:** в TextEdit набрать `руддщ ` (пробел) и `руддщ,` → корректируется, как раньше.
9. **Устойчивость tap'а:** печатать в течение минуты в разных приложениях, чередуя Enter и пробел → приложение не «немеет».

- [ ] **Step 5: Обновить CLAUDE.md**

В `CLAUDE.md`, раздел «Два пути срабатывания (гибрид)», в пункт 2 (ретроактивный) дописать в конце:

```markdown
   Исключение — Enter и Tab: для них `applyCorrection` вызывается синхронно (`applyCorrectionNow`), минуя `correctionDelay`.
```

В раздел «Ключевые решения, которые легко сломать» добавить два пункта после пункта про `correctionDelay`:

```markdown
- **Enter и Tab корректируются синхронно, без `correctionDelay`:** задержка существует, чтобы приложение успело напечатать граничный символ до замены, — но Enter и Tab не печатают видимого символа, зато немедленно запускают действие приложения (навигация, отправка формы, смена фокуса). Через 50 мс браузер уже отправил запрос по неправильному адресу, и править нечего. Tap стоит в `.headInsertEventTap`, поэтому работа, сделанная синхронно в callback'е, видна приложению до обработки клавиши. Синтетический Enter при этом не отправляется: в мессенджере это дало бы два сообщения. Путь AX-only — существующий guard в `applyCorrection` отказывается от keystroke-fallback'а на Enter/Tab, поэтому Enter в терминале остаётся неисправленным (осознанное ограничение: синтетические клавиши всё равно встали бы в очередь после уже отправленного Enter).
- **`.tapDisabledByTimeout` / `.tapDisabledByUserInput` пере-включают tap:** система отключает tap, чей callback выполняется слишком долго. `handle` обрабатывает эти типы первой строкой, до `guard type == .keyDown`. Без этого приложение тихо перестаёт работать до перезапуска, а меню продолжает показывать «включено». Особенно важно с тех пор, как Enter выполняет AX-замену прямо в callback'е.
```

- [ ] **Step 6: Коммит**

```bash
git add Sources/LatCyr/InputMonitor.swift CLAUDE.md
git commit -m "feat: correct the word synchronously on Enter and Tab"
```

---

## Проверка полноты

После Task 3 весь план выполнен. Финальная сверка:

```bash
swift build && swift test && git log --oneline -3
```

Ожидание: сборка чистая, все тесты зелёные, три коммита — `fix: score words...`, `fix: re-enable the event tap...`, `feat: correct the word synchronously...`.

Что осталось за рамками (зафиксировано в разделе 7 спецификации, отдельные задачи): Enter в терминале, конверсия самого разделителя (`?` → `,`, `/` → `.`), поведение `ghbdtn,` → «приветб».
