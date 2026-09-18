# Добавление исключений через буфер обмена — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Когда AX-выделение недоступно (терминалы, Electron), пункт меню «Добавить выделенное в исключения» получает слово через синтетический Cmd+C и буфер обмена, восстанавливая прежнее содержимое буфера.

**Architecture:** Валидация слова выносится из `AppDelegate` в чистую функцию `ExceptionWord.normalized(from:)` и покрывается юнит-тестами. Новая тонкая обёртка `ClipboardReader` (NSPasteboard + CGEvent) постит Cmd+C, дожидается изменения `changeCount`, читает строку и восстанавливает снимок буфера. `AppDelegate` вызывает её только тогда, когда `TextFieldController.selectedText()` вернул `nil`.

**Tech Stack:** Swift 5.9, Swift Package Manager (без Xcode), AppKit (`NSPasteboard`, `NSAlert`, `NSMenu`), CoreGraphics (`CGEvent`), XCTest.

Дизайн-документ: `docs/superpowers/specs/2026-09-18-clipboard-exceptions-design.md`.

## Global Constraints

- Сборка и тесты — только через SwiftPM: `swift build`, `swift test`. Xcode-проекта в репозитории нет.
- Юнит-тестами покрываются **только чистые функции**. Обёртки над системными API (`ClipboardReader`) тестируются вручную — юнит-тестов для них писать не нужно.
- Все строки UI — на русском языке, как остальное меню и алерты в `AppDelegate`.
- Коммиты — conventional style (`feat:`, `fix:`, `docs:`), с завершающей строкой `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Поведение в приложениях, где AX работает, меняться не должно: буфер обмена не трогается, синтетические события не посылаются.
- Тайминговые константы ровно такие: `focusRestoreDelay = 0.1`, `pollInterval = 0.02`, `copyTimeout = 0.5` (секунды).

## Структура файлов

| Файл | Что делает |
|---|---|
| `Sources/LatCyr/ExceptionWord.swift` (создать) | Чистая валидация слова-исключения. Без системных зависимостей. |
| `Tests/LatCyrTests/ExceptionWordTests.swift` (создать) | Юнит-тесты для неё. |
| `Sources/LatCyr/ClipboardReader.swift` (создать) | Тонкая обёртка: Cmd+C → чтение буфера → восстановление снимка. |
| `Sources/LatCyr/AppDelegate.swift` (изменить) | Fallback на буфер обмена, общий хвост валидации, новый текст ошибки. |
| `CLAUDE.md` (изменить) | Новая обёртка в списке компонентов, новый путь в описании исключений, новый тестовый класс. |

Файлы `InputMonitor.swift`, `KeystrokeSimulator.swift`, `TextFieldController.swift`, `ExceptionStore.swift` **не меняются**.

---

### Task 1: Чистая валидация слова-исключения

Сейчас валидация живёт приватным методом `AppDelegate.normalizedExceptionWord(from:)` и не покрыта тестами. С приходом буфера обмена входные данные становятся грязнее (копия строки из терминала несёт хвостовой перевод строки, вставленный текст — неразрывные пробелы), поэтому функция выносится в отдельный файл и покрывается тестами. Поведение не меняется.

**Files:**
- Create: `Sources/LatCyr/ExceptionWord.swift`
- Create: `Tests/LatCyrTests/ExceptionWordTests.swift`
- Modify: `Sources/LatCyr/AppDelegate.swift` (строки 111–125 — вызов; строки 145–156 — удаляемый приватный метод)

**Interfaces:**
- Consumes: ничего из предыдущих задач.
- Produces: `enum ExceptionWord { static func normalized(from text: String) -> String? }` — Task 2 использует её через `AppDelegate.addWordToExceptions(from:)`.

- [ ] **Step 1: Написать падающий тест**

Создай `Tests/LatCyrTests/ExceptionWordTests.swift`:

```swift
import XCTest
@testable import LatCyr

final class ExceptionWordTests: XCTestCase {
    func testLatinWord() {
        XCTAssertEqual(ExceptionWord.normalized(from: "http"), "http")
    }

    func testCyrillicWord() {
        XCTAssertEqual(ExceptionWord.normalized(from: "привет"), "привет")
    }

    func testCyrillicYo() {
        XCTAssertEqual(ExceptionWord.normalized(from: "ёлка"), "ёлка")
    }

    func testLowercasesUpperAndMixedCase() {
        XCTAssertEqual(ExceptionWord.normalized(from: "HTTP"), "http")
        XCTAssertEqual(ExceptionWord.normalized(from: "HtTp"), "http")
        XCTAssertEqual(ExceptionWord.normalized(from: "Привет"), "привет")
    }

    func testTrimsSurroundingWhitespaceAndNewline() {
        // Копия строки из терминала обычно несёт хвостовой перевод строки.
        XCTAssertEqual(ExceptionWord.normalized(from: "  http\n"), "http")
        XCTAssertEqual(ExceptionWord.normalized(from: "\thttp\t"), "http")
        // U+00A0 NO-BREAK SPACE — категория Zs, входит в .whitespacesAndNewlines.
        XCTAssertEqual(ExceptionWord.normalized(from: "\u{00A0}http\u{00A0}"), "http")
    }

    func testRejectsMixedScripts() {
        // "hеllo": «е» здесь кириллическая U+0435, а не латинская "e".
        XCTAssertNil(ExceptionWord.normalized(from: "h\u{0435}llo"))
    }

    func testRejectsDigitsAndPunctuation() {
        XCTAssertNil(ExceptionWord.normalized(from: "http2"))
        XCTAssertNil(ExceptionWord.normalized(from: "http."))
        XCTAssertNil(ExceptionWord.normalized(from: "well-known"))
        XCTAssertNil(ExceptionWord.normalized(from: "youtube.com"))
    }

    func testRejectsMultipleWords() {
        XCTAssertNil(ExceptionWord.normalized(from: "hello world"))
    }

    func testRejectsEmptyAndWhitespaceOnly() {
        XCTAssertNil(ExceptionWord.normalized(from: ""))
        XCTAssertNil(ExceptionWord.normalized(from: "   \n"))
    }
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `swift test --filter ExceptionWordTests`
Expected: FAIL — сборка не проходит, `cannot find 'ExceptionWord' in scope`.

- [ ] **Step 3: Написать минимальную реализацию**

Создай `Sources/LatCyr/ExceptionWord.swift`:

```swift
import Foundation

/// Валидация слова, добавляемого в список исключений. Чистая функция без
/// системных зависимостей — полностью покрыта юнит-тестами. Вынесена из
/// AppDelegate потому, что путь через буфер обмена (ClipboardReader) даёт
/// более грязный вход, чем AX-выделение: копия строки из терминала несёт
/// хвостовой перевод строки, вставленный текст — неразрывные пробелы.
enum ExceptionWord {
    /// Слово целиком из одного алфавита — латиницы или кириллицы (а-я и ё),
    /// в нижнем регистре и без окружающих пробелов. nil для всего
    /// остального: пустая строка, цифры, пунктуация, смешение алфавитов,
    /// несколько слов.
    static func normalized(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        let isLatin = lower.unicodeScalars.allSatisfy { ("a"..."z").contains($0) }
        let isCyrillic = lower.unicodeScalars.allSatisfy { (0x0430...0x044F).contains($0.value) || $0.value == 0x0451 }
        guard isLatin || isCyrillic else { return nil }
        return lower
    }
}
```

- [ ] **Step 4: Запустить тест и убедиться, что он проходит**

Run: `swift test --filter ExceptionWordTests`
Expected: PASS, 9 тестов.

- [ ] **Step 5: Переключить `AppDelegate` на новую функцию**

В `Sources/LatCyr/AppDelegate.swift` замени тело `addSelectedWordToExceptions` (сейчас строки 111–125) на вариант с общим хвостом. Task 2 добавит в него ветку с буфером обмена, здесь только вынос хвоста:

```swift
    @objc private func addSelectedWordToExceptions() {
        guard let raw = textFieldController.selectedText() else {
            showAlert(message: "Не удалось прочитать выделение. В терминалах и некоторых приложениях это не поддерживается.")
            return
        }
        addWordToExceptions(from: raw)
    }

    /// Общий хвост путей получения слова — через AX и через буфер обмена, —
    /// чтобы слово проходило одну и ту же валидацию и давало одни и те же
    /// сообщения, каким бы путём оно ни пришло.
    private func addWordToExceptions(from raw: String) {
        guard let word = ExceptionWord.normalized(from: raw) else {
            showAlert(message: "Выделите слово на одном языке — русском или английском.")
            return
        }
        if inputMonitor.exceptionStore.add(word) {
            showAlert(message: "Добавлено в исключения: \(word)")
        } else {
            showAlert(message: "Уже в списке исключений: \(word)")
        }
    }
```

Затем удали полностью приватный метод `normalizedExceptionWord(from:)` вместе с его doc-комментарием (сейчас строки 145–156 — блок, начинающийся с `/// Accepts a word consisting entirely of one alphabet` и заканчивающийся закрывающей скобкой метода).

- [ ] **Step 6: Собрать и прогнать все тесты**

Run: `swift build && swift test`
Expected: сборка без ошибок и предупреждений; все тесты проходят (`TextConverterTests`, `LanguageDetectorTests`, `ExceptionWordTests`).

- [ ] **Step 7: Коммит**

```bash
git add Sources/LatCyr/ExceptionWord.swift Tests/LatCyrTests/ExceptionWordTests.swift Sources/LatCyr/AppDelegate.swift
git commit -m "refactor: extract exception-word validation into a tested pure function

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Чтение выделения через буфер обмена

**Files:**
- Create: `Sources/LatCyr/ClipboardReader.swift`
- Modify: `Sources/LatCyr/AppDelegate.swift` (свойство рядом с `textFieldController` на строке 6; метод `addSelectedWordToExceptions`)
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: `ExceptionWord.normalized(from:)` и `AppDelegate.addWordToExceptions(from:)` из Task 1; `KeystrokeSimulator.eventMarker` (`static let eventMarker: Int64`, уже существует).
- Produces: `final class ClipboardReader { func copySelection(completion: @escaping (String?) -> Void) }`.

- [ ] **Step 1: Создать `ClipboardReader`**

Создай `Sources/LatCyr/ClipboardReader.swift`:

```swift
import AppKit
import CoreGraphics

/// Читает текущее выделение фронтального приложения через буфер обмена —
/// для случаев, где это не умеет AX: в терминалах и Electron-приложениях
/// видимый текст не является читаемым AX-значением, и
/// kAXSelectedTextAttribute приходит пустым. Cmd+C обрабатывает само
/// приложение, поэтому путь работает везде, где есть команда «Копировать».
///
/// Тонкая обёртка над NSPasteboard и CGEvent, как KeystrokeSimulator:
/// чистой логики нет, проверяется вручную, а не юнит-тестами.
final class ClipboardReader {
    /// kVK_ANSI_C.
    private static let cKeyCode: CGKeyCode = 8

    /// Действие пункта меню срабатывает в момент закрытия меню, а фокус
    /// возвращается приложению не мгновенно: Cmd+C, посланный раньше,
    /// уйдёт в закрывающееся меню. Тюнинг-параметр, как
    /// InputMonitor.correctionDelay.
    private let focusRestoreDelay: TimeInterval = 0.1

    /// Шаг опроса changeCount.
    private let pollInterval: TimeInterval = 0.02

    /// Сколько ждать ответа приложения на Cmd+C, прежде чем сдаться.
    private let copyTimeout: TimeInterval = 0.5

    /// Постит синтетический Cmd+C, отдаёт скопированную строку в
    /// `completion` и восстанавливает прежнее содержимое буфера обмена.
    /// `nil` — приложение не ответило за `copyTimeout` либо положило в
    /// буфер не-текст. `completion` всегда вызывается на главной очереди.
    func copySelection(completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotItems(of: pasteboard)
        let changeCountBefore = pasteboard.changeCount

        DispatchQueue.main.asyncAfter(deadline: .now() + focusRestoreDelay) {
            guard self.postCopyChord() else {
                completion(nil)
                return
            }
            let deadline = Date().addingTimeInterval(self.copyTimeout)
            self.waitForChange(from: changeCountBefore, deadline: deadline) { changed in
                guard changed else {
                    // Ничего не пришло: в буфере лежит ровно то, что лежало,
                    // и восстановление только затёрло бы содержимое, которое
                    // приложение-владелец отдаёт лениво.
                    completion(nil)
                    return
                }
                let text = pasteboard.string(forType: .string)
                self.restore(snapshot, to: pasteboard)
                // Пустую строку трактуем как отсутствие текста — так же,
                // как это делает TextFieldController.selectedText().
                completion((text?.isEmpty ?? true) ? nil : text)
            }
        }
    }

    // MARK: - Private

    /// Глубокая копия: после clearContents() живые NSPasteboardItem
    /// становятся недействительными, поэтому данные всех типов нужно
    /// материализовать сейчас.
    private func snapshotItems(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }

    private func postCopyChord() -> Bool {
        // Оба события конструируются до отправки любого из них, чтобы
        // сбой на keyUp не оставил непарный keyDown.
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: Self.cKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: Self.cKeyCode, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // InputMonitor.handle пропускает события с этой меткой, поэтому наш
        // собственный event tap не заведёт синтетический Cmd+C в буфер слова.
        down.setIntegerValueField(.eventSourceUserData, value: KeystrokeSimulator.eventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: KeystrokeSimulator.eventMarker)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    /// Опрос changeCount через очередь, а не через сон: run loop должен
    /// продолжать крутиться, чтобы меню дозакрылось, а фокус вернулся в
    /// приложение, которому мы только что послали Cmd+C.
    private func waitForChange(
        from changeCountBefore: Int,
        deadline: Date,
        completion: @escaping (Bool) -> Void
    ) {
        if NSPasteboard.general.changeCount != changeCountBefore {
            completion(true)
            return
        }
        guard Date() < deadline else {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            self.waitForChange(from: changeCountBefore, deadline: deadline, completion: completion)
        }
    }
}
```

- [ ] **Step 2: Подключить fallback в `AppDelegate`**

В `Sources/LatCyr/AppDelegate.swift` добавь свойство сразу после `textFieldController` (строка 6):

```swift
    private let clipboardReader = ClipboardReader()
```

Замени `addSelectedWordToExceptions` (тело из Task 1) на вариант с fallback:

```swift
    @objc private func addSelectedWordToExceptions() {
        if let selection = textFieldController.selectedText() {
            addWordToExceptions(from: selection)
            return
        }
        // AX-выделения нет — типично для терминалов и Electron-приложений.
        // Спрашиваем само приложение, синтетическим Cmd+C.
        clipboardReader.copySelection { [weak self] copied in
            guard let self else { return }
            guard let copied else {
                self.showAlert(message: "Не удалось получить выделенный текст. Проверьте, что слово выделено.")
                return
            }
            self.addWordToExceptions(from: copied)
        }
    }
```

`addWordToExceptions(from:)` из Task 1 не меняется.

- [ ] **Step 3: Собрать и прогнать тесты**

Run: `swift build && swift test`
Expected: сборка без ошибок и предупреждений; все тесты проходят — юнит-тестов на `ClipboardReader` нет и не должно быть.

- [ ] **Step 4: Упаковать `.app` для ручной проверки**

Run: `./scripts/package-app.sh`
Expected: собран `dist/LatCyr.app`.

Учти: `package-app.sh` переподписывает бандл и **сбрасывает уже выданные TCC-разрешения**. После упаковки заново выдай `dist/LatCyr.app` разрешения Accessibility и Input Monitoring в System Settings → Privacy & Security, затем `open dist/LatCyr.app`.

- [ ] **Step 5: Ручная проверка**

Пройди весь список, отмечая результат каждого пункта:

| # | Сценарий | Ожидаемо |
|---|---|---|
| 1 | Terminal.app: выделить слово мышью → меню LatCyr → «Добавить выделенное в исключения» | Алерт «Добавлено в исключения: …»; в буфере обмена прежнее содержимое |
| 2 | iTerm2 — то же | То же |
| 3 | VS Code (Electron) — то же | То же |
| 4 | Safari: выделить слово в текстовом поле → тот же пункт меню | Слово добавлено; буфер обмена **не тронут** (сработал AX-путь) |
| 5 | TextEdit — то же | То же |
| 6 | Terminal.app, ничего не выделено | Алерт «Не удалось получить выделенный текст…»; буфер не тронут |
| 7 | Скопировать картинку → Terminal.app, выделить слово → пункт меню | Слово добавлено; картинка в буфере на месте (проверить вставкой) |
| 8 | Скопировать файл в Finder → Terminal.app, выделить слово → пункт меню | Слово добавлено; файл вставляется как прежде |
| 9 | Terminal.app: выделить два слова через пробел → пункт меню | Алерт «Выделите слово на одном языке…»; буфер восстановлен |
| 10 | После пунктов 1–3 набрать добавленное слово в неправильной раскладке | Слово исправляется — исключение работает |

Если пункт 1 даёт таймаут, проверь гипотезу «фокус не успел вернуться»: временно увеличь `focusRestoreDelay` до 0.25 и повтори. Если помогло — это и есть причина; оставь 0.1 и сообщи о находке при ревью, менять константу без обсуждения не нужно.

- [ ] **Step 6: Обновить `CLAUDE.md`**

Три точечные правки.

1. В разделе «Архитектура», абзац «Ключевой принцип изоляции», в перечислении тонких обёрток — `(`LayoutManager`, `TextFieldController`, `PermissionManager`, `InputMonitor`)` заменить на:

```
(`LayoutManager`, `TextFieldController`, `PermissionManager`, `InputMonitor`, `ClipboardReader`)
```

2. В разделе «Ключевые решения», в пункте про слова-исключения, фразу «идут в `~/Library/Application Support/LatCyr/exceptions.txt` через пункт меню «Добавить выделенное в исключения», переживают переупаковку» заменить на:

```
идут в `~/Library/Application Support/LatCyr/exceptions.txt` через пункт меню «Добавить выделенное в исключения», переживают переупаковку. Пункт меню читает выделение через AX (`TextFieldController.selectedText`), а если AX-выделения нет (терминалы, Electron) — через `ClipboardReader`: синтетический Cmd+C, ожидание изменения `NSPasteboard.changeCount` (единственный надёжный признак, что копирование состоялось — `CGEvent.post` ничего не возвращает), чтение строки и восстановление снимка буфера. Cmd+C помечен `KeystrokeSimulator.eventMarker`, поэтому `InputMonitor.handle` его игнорирует. Ожидание асинхронное, а не через сон: заблокировав главный поток прямо в обработчике пункта меню, мы не дали бы меню дозакрыться, а фокусу — вернуться в приложение, то есть сломали бы ровно то, чего ждём.
```

3. В разделе «Тесты» фразу «Покрыты только чистые функции: `TextConverterTests` (…) и `LanguageDetectorTests` (…)» дополнить третьим классом, а список ручных проверок — новой обёрткой. Заменить «Системные компоненты (CGEventTap, TIS, AX, файловый I/O `ExceptionStore`/`HybridAppStore`) проверяются вручную» на:

```
`ExceptionWordTests` покрывает валидацию слова-исключения (оба алфавита, «ё», регистр, обрезка пробелов и переводов строки, отказ на смешении алфавитов, цифрах, пунктуации, нескольких словах и пустой строке). Системные компоненты (CGEventTap, TIS, AX, файловый I/O `ExceptionStore`/`HybridAppStore`, буфер обмена `ClipboardReader`) проверяются вручную
```

- [ ] **Step 7: Коммит**

```bash
git add Sources/LatCyr/ClipboardReader.swift Sources/LatCyr/AppDelegate.swift CLAUDE.md
git commit -m "feat: read the selection through the clipboard when AX has none

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Соответствие дизайн-документу

| Раздел спеки | Задача |
|---|---|
| §3 `ClipboardReader`, алгоритм из 6 шагов | Task 2, Step 1 |
| §3 «Почему не через `KeystrokeSimulator`» | Task 2, Step 1 — собственный `postCopyChord`, общий только `eventMarker` |
| §3 «Почему Cmd+C не ломает работу монитора» | Task 2, Step 1 — метка `eventMarker`; `InputMonitor` не меняется |
| §3 «Владение» | Task 2, Step 2 — `clipboardReader` как свойство `AppDelegate` |
| §4 Поток в `AppDelegate`, общий хвост, новый текст ошибки | Task 1 Step 5 (хвост) + Task 2 Step 2 (fallback и текст) |
| §5 Тайминг, три константы, асинхронность | Task 2, Step 1 |
| §6 Таблица исходов и сообщений | Task 1 Step 5 + Task 2 Step 2; проверяется пунктами 6, 7, 9 ручного списка |
| §7 Вынос валидации в чистую функцию | Task 1 |
| §8 Автотесты | Task 1, Step 1 |
| §8 Ручные проверки | Task 2, Step 5 |
| §9 Принятые ограничения | Уже зафиксированы в спеке; в коде — комментарии в `ClipboardReader` |
| §10 Границы | Ничего не реализуется — задач нет по построению |
