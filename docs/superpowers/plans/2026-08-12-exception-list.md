# Слова-исключения и гибридные приложения — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a word-exception list that overrides `LanguageDetector`'s score heuristic unconditionally (never convert a correctly-typed exception, always convert its wrong-layout typo), pre-filled with common IT terms and extensible via the menu bar, plus a user-extensible list of "hybrid" apps that reuse the terminal keystroke-fallback mechanism.

**Architecture:** Two new thin file-backed stores (`ExceptionStore`, `HybridAppStore`, sharing a `LineFile` I/O helper) sit alongside the existing thin system wrappers. `LanguageDetector.isWrongLayout` gains an `exceptions: Set<String>` parameter checked before score computation. `KeystrokeSimulator.isTerminalFrontmost` is renamed to `usesKeystrokeFallback` and consults both the existing hardcoded terminal list and `HybridAppStore`. `InputMonitor` owns both stores and loads them once at construction; `AppDelegate` reads/writes them through two new menu items.

**Tech Stack:** Swift Package Manager, Foundation (`FileManager`, `FileHandle`), AppKit (`NSAlert`, `NSWorkspace`), XCTest.

## Global Constraints

- Слово-исключение состоит целиком из букв одного алфавита (кириллица либо латиница) — смешение не поддерживается.
- Проверка исключений действует только на ретроактивном пути (полное слово на границе) — проактивные пути (2-символьный сигнал, `/`-сигнал) не меняются.
- Бандловый список слов копируется в `.app` при упаковке (`package-app.sh`), read-only в рантайме; отсутствует при `swift run` (dev-режим) — ожидаемо, не ошибка.
- Динамические файлы — `~/Library/Application Support/LatCyr/exceptions.txt` и `.../hybrid-apps.txt`: простой текст, одна запись на строку, `#`-строки и пустые строки игнорируются, значения приводятся к нижнему регистру при чтении.
- Файлы читаются один раз при старте; внешняя правка в Finder применяется только после перезапуска приложения — не live-reload.
- `ExceptionStore`/`HybridAppStore` — тонкие обёртки над файловым I/O, тестируются вручную (как `PermissionManager`), не входят в автоматический набор юнит-тестов.
- Коммиты — conventional style (`feat:`, `fix:`, `docs:`).

---

## Task 1: `LanguageDetector.isWrongLayout` — параметр `exceptions`

**Files:**
- Modify: `Sources/LatCyr/LanguageDetector.swift:116-134` (функция `isWrongLayout`)
- Modify: `Sources/LatCyr/InputMonitor.swift:121` (единственный вызов вне тестов)
- Modify: `Tests/LatCyrTests/LanguageDetectorTests.swift` (все существующие вызовы + новые тесты)

**Interfaces:**
- Produces: `LanguageDetector.isWrongLayout(word: String, currentLayoutIsRussian: Bool, exceptions: Set<String>) -> Bool` — новая обязательная сигнатура, используется всеми последующими задачами, вызывающими детекцию.

- [ ] **Step 1: Обновить тестовый файл — все существующие вызовы + новые тесты**

Замени `Tests/LatCyrTests/LanguageDetectorTests.swift` целиком на:

```swift
import XCTest
@testable import LatCyr

final class LanguageDetectorTests: XCTestCase {
    // Russian typed in English layout → detect
    func testRussianTypedInEnglishLayout() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ghbdtn", currentLayoutIsRussian: false, exceptions: [])) // привет
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "vbh", currentLayoutIsRussian: false, exceptions: []))     // мир
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ntcn", currentLayoutIsRussian: false, exceptions: []))    // тест
    }

    // Words containing letters typed via a punctuation key (ё, х, ъ, ж, э,
    // б, ю share a physical key with `, [, ], ;, ', ,, .) must still be
    // detected as a whole, not cut short at the punctuation character.
    func testWordWithAmbiguousPunctuationLetter() {
        XCTAssertEqual(TextConverter.toCyrillic("ndj."), "твою")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ndj.", currentLayoutIsRussian: false, exceptions: [])) // твою
    }

    // English typed in Russian layout → detect
    func testEnglishTypedInRussianLayout() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "руддщ", currentLayoutIsRussian: true, exceptions: []))   // hello
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "цщкду", currentLayoutIsRussian: true, exceptions: []))   // world
    }

    // Correct words → never touch
    func testCorrectWordsNotTouched() {
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "hello", currentLayoutIsRussian: false, exceptions: []))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "the", currentLayoutIsRussian: false, exceptions: []))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "world", currentLayoutIsRussian: false, exceptions: []))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "привет", currentLayoutIsRussian: true, exceptions: []))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "мир", currentLayoutIsRussian: true, exceptions: []))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "тест", currentLayoutIsRussian: true, exceptions: []))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "следующий", currentLayoutIsRussian: true, exceptions: []))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "здравствуйте", currentLayoutIsRussian: true, exceptions: []))
    }

    // Short words → never touch
    func testShortWordsNotTouched() {
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "vb", currentLayoutIsRussian: false, exceptions: []))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "gh", currentLayoutIsRussian: false, exceptions: []))
    }

    // Words with digits → never touch
    func testWordsWithDigitsNotTouched() {
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "ghbdtn123", currentLayoutIsRussian: false, exceptions: []))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "привет1", currentLayoutIsRussian: true, exceptions: []))
    }

    // Exception words — a Latin exception overrides the score heuristic in
    // both directions. "sdd" typed correctly under the English layout is a
    // real false positive of the plain heuristic (short, consonant-heavy
    // acronyms score ambiguously) — exactly what the whitelist half fixes.
    func testExceptionWordNeverConverted() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "sdd", currentLayoutIsRussian: false, exceptions: []))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "sdd", currentLayoutIsRussian: false, exceptions: ["sdd"]))
    }

    // "ssl" mistyped as "ыыд" under the Russian layout (toLatin("ыыд") ==
    // "ssl"): both scores are too low for the ordinary heuristic to catch
    // it — exactly what the forced-correction half fixes.
    func testExceptionWordAlwaysCorrected() {
        XCTAssertEqual(TextConverter.toLatin("ыыд"), "ssl")
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "ыыд", currentLayoutIsRussian: true, exceptions: []))
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ыыд", currentLayoutIsRussian: true, exceptions: ["ssl"]))
    }

    // Same two behaviors, mirrored for a Cyrillic exception word — proves
    // the check isn't hardcoded to Latin-only exceptions.
    func testCyrillicExceptionWordSymmetric() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ффф", currentLayoutIsRussian: true, exceptions: []))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "ффф", currentLayoutIsRussian: true, exceptions: ["ффф"]))

        XCTAssertEqual(TextConverter.toCyrillic("dep"), "вуз")
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "dep", currentLayoutIsRussian: false, exceptions: []))
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "dep", currentLayoutIsRussian: false, exceptions: ["вуз"]))
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

- [ ] **Step 2: Убедиться, что тесты не компилируются (сигнатура ещё старая)**

Run: `swift test --filter LanguageDetectorTests`
Expected: FAIL to build — `extra argument 'exceptions' in call`

- [ ] **Step 3: Обновить `isWrongLayout` в `LanguageDetector.swift`**

В `Sources/LatCyr/LanguageDetector.swift` замени функцию `isWrongLayout` (строки 116-134) на:

```swift
    /// Decide whether `word` (typed in the current layout) was meant to be
    /// typed in the other layout. `exceptions` overrides the score
    /// heuristic unconditionally: a word that is itself an exception is
    /// never flagged; a word whose conversion is an exception is always
    /// flagged — regardless of `russianThreshold`/`englishThreshold`/`diffThreshold`.
    public static func isWrongLayout(
        word: String, currentLayoutIsRussian: Bool, exceptions: Set<String>
    ) -> Bool {
        let lower = word.lowercased()
        guard lower.count >= minWordLength else { return false }
        guard lower.allSatisfy({ $0.isLetter || TextConverter.ambiguousLetterSymbols.contains($0) }) else { return false }

        if exceptions.contains(lower) { return false }

        let converted = currentLayoutIsRussian ? TextConverter.toLatin(lower) : TextConverter.toCyrillic(lower)
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

- [ ] **Step 4: Обновить вызов в `InputMonitor.swift`**

В `Sources/LatCyr/InputMonitor.swift:121`, замени:

```swift
            } else if LanguageDetector.isWrongLayout(word: currentWord, currentLayoutIsRussian: currentLayoutIsRussian) {
```

на (временный литерал — заменится на реальный стор в Task 6):

```swift
            } else if LanguageDetector.isWrongLayout(word: currentWord, currentLayoutIsRussian: currentLayoutIsRussian, exceptions: []) {
```

- [ ] **Step 5: Запустить полный набор тестов**

Run: `swift test`
Expected: PASS — все тесты, включая 3 новых, зелёные.

- [ ] **Step 6: Commit**

```bash
git add Sources/LatCyr/LanguageDetector.swift Sources/LatCyr/InputMonitor.swift Tests/LatCyrTests/LanguageDetectorTests.swift
git commit -m "feat: add exceptions parameter to LanguageDetector.isWrongLayout"
```

---

## Task 2: Бандловый список слов-исключений + упаковка

**Files:**
- Create: `Resources/exceptions.txt` (корень репозитория — не под `Sources/LatCyr/`, чтобы Swift Package Manager не считал файл «unhandled» ресурсом цели и не выдавал warning при сборке; см. rationale ниже)
- Modify: `scripts/package-app.sh`

**Interfaces:**
- Produces: `Resources/exceptions.txt` — читается `ExceptionStore` (Task 3) через `Bundle.main.resourceURL` в упакованном `.app`.

**Rationale (почему не `Sources/LatCyr/Resources/`):** SPM трактует любой нераспознанный файл внутри `Sources/<Target>/` как «unhandled» и печатает warning при каждой сборке, если он не объявлен через `resources:` в `Package.swift`. Проект сознательно не используется SPM resource bundling (см. дизайн — простое копирование скриптом, как уже делается с бинарником), поэтому файл живёт вне дерева, которое сканирует SPM.

- [ ] **Step 1: Создать `Resources/exceptions.txt`**

```
# Английские IT-термины и протоколы — бандловый список исключений LatCyr.
# Никогда не конвертируются, если набраны верно; всегда исправляются, если
# набраны в чужой раскладке. Дополнить можно через меню LatCyr или вручную
# отредактировав ~/Library/Application Support/LatCyr/exceptions.txt.
http
https
www
ssl
tls
ssh
ftp
sftp
dns
vpn
tcp
udp
ip
url
uri
api
sdk
sdd
ide
cli
gui
ui
ux
cpu
gpu
ram
rom
usb
hdd
ssd
json
xml
html
css
sql
nosql
git
svn
npm
pip
docker
kubernetes
oauth
jwt
rest
soap
grpc
cdn
dom
ajax
spa
```

- [ ] **Step 2: Обновить `scripts/package-app.sh` — копировать файл в бандл**

В `scripts/package-app.sh`, после строки `mkdir -p "$DIST/Contents/MacOS"` добавь создание Resources и копирование:

```bash
mkdir -p "$DIST/Contents/MacOS"
mkdir -p "$DIST/Contents/Resources"

cp ".build/release/${APP_NAME}" "$DIST/Contents/MacOS/${APP_NAME}"
cp "Resources/exceptions.txt" "$DIST/Contents/Resources/exceptions.txt"
```

(заменяет существующие строки `mkdir -p "$DIST/Contents/MacOS"` и `cp ".build/release/${APP_NAME}" ...` — остальной файл без изменений)

- [ ] **Step 3: Прогнать упаковку и проверить, что файл попал в бандл**

Run: `./scripts/package-app.sh && cat dist/LatCyr.app/Contents/Resources/exceptions.txt | head -5`
Expected: сборка завершается `Packaged: dist/LatCyr.app`, вывод показывает первые строки списка (комментарий + `http`).

- [ ] **Step 4: Commit**

```bash
git add Resources/exceptions.txt scripts/package-app.sh
git commit -m "feat: bundle default IT-term exception list into the app package"
```

---

## Task 3: `LineFile` helper + `ExceptionStore`

**Files:**
- Create: `Sources/LatCyr/LineFile.swift`
- Create: `Sources/LatCyr/ExceptionStore.swift`

**Interfaces:**
- Consumes: nothing new (pure `Foundation`).
- Produces:
  - `LineFile.read(_ url: URL) -> Set<String>`
  - `LineFile.append(_ value: String, to url: URL)`
  - `ExceptionStore.words: Set<String>` (read-only, populated by `load()`)
  - `ExceptionStore.load()`
  - `ExceptionStore.contains(_ word: String) -> Bool`
  - `ExceptionStore.add(_ word: String) -> Bool`
  - `ExceptionStore.init(bundledURL: URL?, dynamicURL: URL)` — используется Task 6 (`InputMonitor`).

- [ ] **Step 1: Создать `Sources/LatCyr/LineFile.swift`**

```swift
import Foundation

/// Shared plain-text line-file I/O for ExceptionStore and HybridAppStore:
/// one value per line, blank lines and `#`-prefixed comments ignored,
/// values lowercased on read.
enum LineFile {
    static func read(_ url: URL) -> Set<String> {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var result: Set<String> = []
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            result.insert(line.lowercased())
        }
        return result
    }

    /// Appends `value` as its own line, creating the parent directory and
    /// file if either is missing.
    static func append(_ value: String, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let line = value + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
```

- [ ] **Step 2: Создать `Sources/LatCyr/ExceptionStore.swift`**

```swift
import Foundation

/// Owns the merged set of exception words: never converted when typed
/// correctly, always converted when typed in the wrong layout — regardless
/// of LanguageDetector's score thresholds (see isWrongLayout). Bundled
/// defaults ship inside the .app; user additions go to a separate file
/// that survives repackaging (package-app.sh re-signs and drops TCC
/// permissions on every run, but never touches Application Support).
final class ExceptionStore {
    private(set) var words: Set<String> = []

    private let bundledURL: URL?
    private let dynamicURL: URL

    init(
        bundledURL: URL? = Bundle.main.resourceURL?.appendingPathComponent("exceptions.txt"),
        dynamicURL: URL = ExceptionStore.defaultDynamicURL
    ) {
        self.bundledURL = bundledURL
        self.dynamicURL = dynamicURL
    }

    static var defaultDynamicURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LatCyr/exceptions.txt")
    }

    /// Reads both files (whichever exist) into `words`. Call once at
    /// startup — later edits go through `add`, not another `load`.
    func load() {
        var merged: Set<String> = []
        if let bundledURL { merged.formUnion(LineFile.read(bundledURL)) }
        merged.formUnion(LineFile.read(dynamicURL))
        words = merged
    }

    func contains(_ word: String) -> Bool {
        words.contains(word.lowercased())
    }

    /// Adds `word` to the dynamic file and to `words`. Returns false if it
    /// was already present (from either file) — no duplicate line written.
    @discardableResult
    func add(_ word: String) -> Bool {
        let lower = word.lowercased()
        guard !words.contains(lower) else { return false }
        words.insert(lower)
        LineFile.append(lower, to: dynamicURL)
        return true
    }
}
```

- [ ] **Step 3: Собрать проект**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/LatCyr/LineFile.swift Sources/LatCyr/ExceptionStore.swift
git commit -m "feat: add ExceptionStore for user- and bundle-provided exception words"
```

---

## Task 4: `HybridAppStore`

**Files:**
- Create: `Sources/LatCyr/HybridAppStore.swift`

**Interfaces:**
- Consumes: `LineFile.read`, `LineFile.append` (Task 3).
- Produces:
  - `HybridAppStore.bundleIDs: Set<String>`
  - `HybridAppStore.load()`
  - `HybridAppStore.contains(_ bundleID: String) -> Bool`
  - `HybridAppStore.add(_ bundleID: String) -> Bool`
  - `HybridAppStore.init(dynamicURL: URL)` — используется Task 5/6.

- [ ] **Step 1: Создать `Sources/LatCyr/HybridAppStore.swift`**

```swift
import Foundation

/// User-registered bundle identifiers of apps whose visible text is a
/// rendered view rather than an editable AX string (VS Code's integrated
/// terminal, other Electron-based apps, etc.) — the same problem the
/// hardcoded terminal list in KeystrokeSimulator solves, extended here by
/// the user via the menu instead of a code change.
final class HybridAppStore {
    private(set) var bundleIDs: Set<String> = []

    private let dynamicURL: URL

    init(dynamicURL: URL = HybridAppStore.defaultDynamicURL) {
        self.dynamicURL = dynamicURL
    }

    static var defaultDynamicURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LatCyr/hybrid-apps.txt")
    }

    func load() {
        bundleIDs = LineFile.read(dynamicURL)
    }

    func contains(_ bundleID: String) -> Bool {
        bundleIDs.contains(bundleID.lowercased())
    }

    @discardableResult
    func add(_ bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        guard !bundleIDs.contains(lower) else { return false }
        bundleIDs.insert(lower)
        LineFile.append(lower, to: dynamicURL)
        return true
    }
}
```

- [ ] **Step 2: Собрать проект**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/LatCyr/HybridAppStore.swift
git commit -m "feat: add HybridAppStore for user-registered keystroke-fallback apps"
```

---

## Task 5: `KeystrokeSimulator` — `usesKeystrokeFallback` + `HybridAppStore`

**Files:**
- Modify: `Sources/LatCyr/KeystrokeSimulator.swift`

**Interfaces:**
- Consumes: `HybridAppStore.contains(_:)` (Task 4).
- Produces: `KeystrokeSimulator.init(hybridAppStore: HybridAppStore)`, `KeystrokeSimulator.usesKeystrokeFallback: Bool` (замена `isTerminalFrontmost`), `KeystrokeSimulator.terminalBundleIDs` (доступность меняется на internal — используется Task 8).

- [ ] **Step 1: Обновить `Sources/LatCyr/KeystrokeSimulator.swift`**

Замени:

```swift
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
    ]

    /// Whether the frontmost application is a known terminal that doesn't
    /// support AX-based text replacement.
    var isTerminalFrontmost: Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return Self.terminalBundleIDs.contains(id)
    }
```

на:

```swift
    /// Not private: AppDelegate checks this list before offering to
    /// register an app as hybrid, so it doesn't suggest adding one that's
    /// already covered.
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
    ]

    private let hybridAppStore: HybridAppStore

    init(hybridAppStore: HybridAppStore) {
        self.hybridAppStore = hybridAppStore
    }

    /// Whether the frontmost application is a known terminal or a
    /// user-registered hybrid app — either way, AX-based text replacement
    /// doesn't work and keystroke injection is the only option.
    var usesKeystrokeFallback: Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return Self.terminalBundleIDs.contains(id) || hybridAppStore.contains(id)
    }
```

- [ ] **Step 2: Собрать проект (ожидаемо не соберётся — `InputMonitor` ещё создаёт `KeystrokeSimulator()` без аргумента)**

Run: `swift build`
Expected: FAIL — `missing argument for parameter 'hybridAppStore' in call`, а также два места использования `isTerminalFrontmost`, которых больше не существует. Это ожидаемо — исправляется в Task 6.

- [ ] **Step 3: Commit**

```bash
git add Sources/LatCyr/KeystrokeSimulator.swift
git commit -m "feat: rename KeystrokeSimulator.isTerminalFrontmost to usesKeystrokeFallback and add hybrid app support"
```

(Коммит осознанно оставляет пакет не собирающимся — следующий task чинит оба вызывающих места. Это единственная точка плана, где это допустимо, т.к. Task 5 и Task 6 механически неразделимы без временных заглушек, которые пришлось бы тут же убирать.)

---

## Task 6: `InputMonitor` — владение сторами, реальная проводка

**Files:**
- Modify: `Sources/LatCyr/InputMonitor.swift`

**Interfaces:**
- Consumes: `ExceptionStore` (Task 3), `HybridAppStore` (Task 4), `KeystrokeSimulator.init(hybridAppStore:)` / `.usesKeystrokeFallback` (Task 5).
- Produces: `InputMonitor.exceptionStore: ExceptionStore` (internal, не private — читает `AppDelegate` в Task 8), `InputMonitor.hybridAppStore: HybridAppStore` (то же).

- [ ] **Step 1: Обновить объявление свойств и добавить `init()`**

В `Sources/LatCyr/InputMonitor.swift`, замени строки 9-17:

```swift
final class InputMonitor {
    private let layoutManager = LayoutManager()
    private let textFieldController = TextFieldController()
    private let keystrokeSimulator = KeystrokeSimulator()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var appActivationObserver: NSObjectProtocol?
    private(set) var isRunning = false
```

на:

```swift
final class InputMonitor {
    private let layoutManager = LayoutManager()
    private let textFieldController = TextFieldController()
    private let keystrokeSimulator: KeystrokeSimulator
    /// Exposed (not private) so AppDelegate's menu actions can add words —
    /// adding an exception must work whether or not the monitor is running.
    let exceptionStore = ExceptionStore()
    /// Same reasoning as exceptionStore.
    let hybridAppStore = HybridAppStore()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var appActivationObserver: NSObjectProtocol?
    private(set) var isRunning = false

    init() {
        keystrokeSimulator = KeystrokeSimulator(hybridAppStore: hybridAppStore)
        exceptionStore.load()
        hybridAppStore.load()
    }
```

- [ ] **Step 2: Обновить два вызова `isTerminalFrontmost`**

В `Sources/LatCyr/InputMonitor.swift:179`, замени:

```swift
        guard keystrokeSimulator.isTerminalFrontmost else { return }
```

на:

```swift
        guard keystrokeSimulator.usesKeystrokeFallback else { return }
```

В `Sources/LatCyr/InputMonitor.swift:234`, замени:

```swift
        guard keystrokeSimulator.isTerminalFrontmost else { return false }
```

на:

```swift
        guard keystrokeSimulator.usesKeystrokeFallback else { return false }
```

- [ ] **Step 3: Передать реальный набор исключений вместо литерала из Task 1**

В `Sources/LatCyr/InputMonitor.swift:121` (текст после Task 1), замени:

```swift
            } else if LanguageDetector.isWrongLayout(word: currentWord, currentLayoutIsRussian: currentLayoutIsRussian, exceptions: []) {
```

на:

```swift
            } else if LanguageDetector.isWrongLayout(word: currentWord, currentLayoutIsRussian: currentLayoutIsRussian, exceptions: exceptionStore.words) {
```

- [ ] **Step 4: Собрать проект и прогнать тесты**

Run: `swift build && swift test`
Expected: `Build complete!`, все тесты зелёные (Task 1's тесты не зависят от `InputMonitor`, но сборка пакета целиком должна проходить).

- [ ] **Step 5: Commit**

```bash
git add Sources/LatCyr/InputMonitor.swift
git commit -m "feat: wire ExceptionStore and HybridAppStore into InputMonitor"
```

---

## Task 7: `TextFieldController.selectedText()`

**Files:**
- Modify: `Sources/LatCyr/TextFieldController.swift`

**Interfaces:**
- Produces: `TextFieldController.selectedText() -> String?` — используется Task 8 (`AppDelegate`).

- [ ] **Step 1: Добавить метод**

В `Sources/LatCyr/TextFieldController.swift`, после метода `isEditableText` (после строки 36, до `// MARK: -` про `WordAnchor`), добавь:

```swift
    /// The currently selected text in the focused element, if any. Returns
    /// nil for secure fields (anti password-leak) and whenever there's
    /// nothing to read (no focused element, no selection, or an app whose
    /// visible content isn't a real AX value — e.g. a terminal).
    func selectedText() -> String? {
        guard let element = focusedTextElement(), !isSecure(element) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let raw = value else { return nil }
        let text = unsafeBitCast(raw, to: CFString.self) as String
        return text.isEmpty ? nil : text
    }
```

- [ ] **Step 2: Собрать проект**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/LatCyr/TextFieldController.swift
git commit -m "feat: add TextFieldController.selectedText for the exception-word menu action"
```

---

## Task 8: Пункты меню в `AppDelegate`

**Files:**
- Modify: `Sources/LatCyr/AppDelegate.swift`

**Interfaces:**
- Consumes: `inputMonitor.exceptionStore` / `.hybridAppStore` (Task 6), `TextFieldController.selectedText()` (Task 7), `KeystrokeSimulator.terminalBundleIDs` (Task 5).

- [ ] **Step 1: Добавить `textFieldController` и два пункта меню в `buildMenu()`**

В `Sources/LatCyr/AppDelegate.swift`, добавь свойство после `private let permissionManager = PermissionManager()`:

```swift
    private let textFieldController = TextFieldController()
```

Замени блок (строки 45-47):

```swift
        menu.addItem(toggleItem)

        menu.addItem(.separator())
```

на:

```swift
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let addExceptionItem = NSMenuItem(
            title: "Добавить выделенное в исключения",
            action: #selector(addSelectedWordToExceptions),
            keyEquivalent: ""
        )
        addExceptionItem.target = self
        menu.addItem(addExceptionItem)

        let addHybridAppItem = NSMenuItem(
            title: "Добавить текущее приложение как гибридное",
            action: #selector(addCurrentAppAsHybrid),
            keyEquivalent: ""
        )
        addHybridAppItem.target = self
        menu.addItem(addHybridAppItem)

        menu.addItem(.separator())
```

- [ ] **Step 2: Добавить обработчики действий и вспомогательные методы**

В `Sources/LatCyr/AppDelegate.swift`, добавь в секцию `// MARK: - Actions` (после `openPermissions`, перед `setEnabled`):

```swift
    @objc private func addSelectedWordToExceptions() {
        guard let raw = textFieldController.selectedText() else {
            showAlert(message: "Не удалось прочитать выделение. В терминалах и некоторых приложениях это не поддерживается.")
            return
        }
        guard let word = normalizedExceptionWord(from: raw) else {
            showAlert(message: "Выделите слово на одном языке — русском или английском.")
            return
        }
        if inputMonitor.exceptionStore.add(word) {
            showAlert(message: "Добавлено в исключения: \(word)")
        } else {
            showAlert(message: "Уже в списке исключений: \(word)")
        }
    }

    @objc private func addCurrentAppAsHybrid() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            showAlert(message: "Не удалось определить текущее приложение.")
            return
        }
        let name = app.localizedName ?? bundleID
        let alreadyKnown = bundleID == Bundle.main.bundleIdentifier
            || KeystrokeSimulator.terminalBundleIDs.contains(bundleID)
            || inputMonitor.hybridAppStore.contains(bundleID)
        guard !alreadyKnown else {
            showAlert(message: "Уже поддерживается: \(name) (\(bundleID))")
            return
        }
        inputMonitor.hybridAppStore.add(bundleID)
        showAlert(message: "Добавлено как гибридное: \(name) (\(bundleID))")
    }

    /// Accepts a word consisting entirely of one alphabet — Latin or
    /// Cyrillic (а-я plus ё), lowercased and trimmed. Rejects everything
    /// else: empty selection, digits, punctuation, mixed scripts.
    private func normalizedExceptionWord(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        let isLatin = lower.unicodeScalars.allSatisfy { ("a"..."z").contains($0) }
        let isCyrillic = lower.unicodeScalars.allSatisfy { (0x0430...0x044F).contains($0.value) || $0.value == 0x0451 }
        guard isLatin || isCyrillic else { return nil }
        return lower
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "LatCyr"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
```

- [ ] **Step 3: Собрать проект**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Ручная проверка (см. полный чек-лист в Task 10) — быстрый smoke-test**

```bash
./scripts/package-app.sh && open dist/LatCyr.app
```

Открой TextEdit, набери `http`, выдели его, кликни в меню LatCyr «Добавить выделенное в исключения» — должен появиться алерт «Добавлено в исключения: http» (или «Уже в списке», если бандловый список уже его содержит — тоже верно). Проверь: `cat "$HOME/Library/Application Support/LatCyr/exceptions.txt"`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LatCyr/AppDelegate.swift
git commit -m "feat: add menu actions to register exception words and hybrid apps"
```

---

## Task 9: Обновить `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:** нет (документация).

- [ ] **Step 1: Обновить строку про архитектуру и изоляцию (строка 27)**

Замени:

```markdown
Ключевой принцип изоляции: **чистые функции** (`TextConverter`, `LanguageDetector`) — без системных зависимостей, полностью юнит-тестируются; **тонкие обёртки** над системными API (`LayoutManager`, `TextFieldController`, `PermissionManager`, `InputMonitor`) — тестируются только вручную. При изменении эвристики или конвертации тесты — единственная защита, держи их зелёными.
```

на:

```markdown
Ключевой принцип изоляции: **чистые функции** (`TextConverter`, `LanguageDetector`) — без системных зависимостей, полностью юнит-тестируются; **тонкие обёртки** над системными API (`LayoutManager`, `TextFieldController`, `PermissionManager`, `InputMonitor`) — тестируются только вручную. `ExceptionStore` и `HybridAppStore` — тоже тонкие обёртки (файловый I/O), тестируются вручную. При изменении эвристики или конвертации тесты — единственная защита, держи их зелёными.
```

- [ ] **Step 2: Обновить упоминание `isTerminalFrontmost` в разделе про проактивный путь по одному символу (строка 35)**

Замени `keystrokeSimulator.isTerminalFrontmost` на `keystrokeSimulator.usesKeystrokeFallback` в этой строке (текст вокруг не меняется).

- [ ] **Step 3: Обновить bullet про `KeystrokeSimulator` fallback (строка 44) и добавить новый bullet про исключения и гибридные приложения**

В bullet `**\`KeystrokeSimulator\` fallback для терминалов:**` замени оба вхождения `KeystrokeSimulator.isTerminalFrontmost` на `KeystrokeSimulator.usesKeystrokeFallback`.

Сразу после этого bullet добавь новый:

```markdown
- **Слова-исключения (`ExceptionStore`) переопределяют пороги эвристики безусловно:** `LanguageDetector.isWrongLayout` проверяет `exceptions` до вычисления скоров — слово-исключение, набранное верно, никогда не конвертируется; его конверсия в другую раскладку — всегда конвертируется. Действует только на ретроактивном пути (полное слово уже известно на границе) — проактивные сигналы (2 символа, `/`) исключения не учитывают. Бандловый список (английские IT-термины: `http`, `www`, `ssl`, `sdd`, `usb` и т.п.) живёт в `Resources/exceptions.txt` в репозитории и копируется в `.app` `package-app.sh`; пользовательские дополнения (любого алфавита — кириллица или латиница) идут в `~/Library/Application Support/LatCyr/exceptions.txt` через пункт меню «Добавить выделенное в исключения», переживают переупаковку. **Гибридные приложения (`HybridAppStore`)** расширяют список известных терминалов из `KeystrokeSimulator.terminalBundleIDs` пользовательскими bundle ID (пункт меню «Добавить текущее приложение как гибридное») — для Electron-приложений и подобных, где AX тоже не работает. Оба файла читаются один раз при старте; внешняя правка в Finder требует перезапуска приложения.
```

- [ ] **Step 4: Обновить раздел «Тесты» (строка 54)**

Замени:

```markdown
Покрыты только чистые функции: `TextConverterTests` (двусторонняя конвертация, регистр, цифры/символы не трогаются, все 33 буквы, «ё») и `LanguageDetectorTests` (детект «ghbdtn»→привет, «руддщ»→hello, корректные слова не трогаются, короткие слова и слова с цифрами не трогаются, проактивные сигналы, скоры). Системные компоненты (CGEventTap, TIS, AX) проверяются вручную: Terminal, Safari, TextEdit, Notes, парольные поля.
```

на:

```markdown
Покрыты только чистые функции: `TextConverterTests` (двусторонняя конвертация, регистр, цифры/символы не трогаются, все 33 буквы, «ё») и `LanguageDetectorTests` (детект «ghbdtn»→привет, «руддщ»→hello, корректные слова не трогаются, короткие слова и слова с цифрами не трогаются, проактивные сигналы, скоры, слова-исключения в обе стороны для латиницы и кириллицы). Системные компоненты (CGEventTap, TIS, AX, файловый I/O `ExceptionStore`/`HybridAppStore`) проверяются вручную: Terminal, Safari, TextEdit, Notes, парольные поля.
```

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document ExceptionStore, HybridAppStore, and the usesKeystrokeFallback rename"
```

---

## Task 10: Ручная сквозная проверка

**Files:** нет (QA, изменений в код нет).

**Interfaces:** нет.

- [ ] **Step 1: Выдать разрешения упакованному `.app` (если ещё не выданы)**

```bash
./scripts/package-app.sh
open dist/LatCyr.app
```

В System Settings → Privacy & Security выдай `LatCyr.app` Accessibility и Input Monitoring (см. CLAUDE.md — переупаковка сбрасывает уже выданные разрешения, если это не первая упаковка после начала задачи).

- [ ] **Step 2: Бандловое исключение защищает корректно набранный акроним**

В TextEdit, английская раскладка активна, набери `sdd ` (с пробелом). **Ожидаемо:** слово остаётся `sdd`, раскладка не переключается. (До этой задачи `sdd` — реальный ложноположительный кейс эвристики; после — защищено списком.)

- [ ] **Step 3: Бандловое исключение принудительно исправляет опечатку**

Переключись на русскую раскладку (Cmd+Space или явно в LatCyr нет ручного переключателя — переключи системно). В TextEdit набери `ыыд ` (это `ssl`, набранный по ошибке в русской раскладке). **Ожидаемо:** после пробела текст меняется на `ssl `, раскладка переключается на английскую.

- [ ] **Step 4: Добавление слова через меню**

В TextEdit набери любое слово, которого точно нет в списке (например `foobar`), выдели его. Открой меню LatCyr → «Добавить выделенное в исключения». **Ожидаемо:** алерт «Добавлено в исключения: foobar». Проверь:

```bash
tail -1 "$HOME/Library/Application Support/LatCyr/exceptions.txt"
```

Ожидаемо: `foobar`.

- [ ] **Step 5: Повторное добавление — дубликат**

Повтори Step 4 с тем же словом `foobar`. **Ожидаемо:** алерт «Уже в списке исключений: foobar», файл не получает вторую строку.

- [ ] **Step 6: Валидация — смешанный/невалидный текст**

Выдели `foo123` (или любой текст с цифрой/пунктуацией), кликни «Добавить выделенное в исключения». **Ожидаемо:** алерт «Выделите слово на одном языке — русском или английском», файл не меняется.

- [ ] **Step 7: Валидация — кириллическое слово**

В TextEdit набери и выдели `привет`, добавь в исключения. **Ожидаемо:** алерт «Добавлено в исключения: привет». Набери `ghbdtn ` (привет по ошибке в английской раскладке) — **ожидаемо:** принудительно исправляется в `привет`, несмотря на то, что это уже проверялось обычной эвристикой (это не показатель, но убедись, что ничего не сломалось).

- [ ] **Step 8: Терминал — AX-выделение недоступно**

Открой Terminal.app, набери и выдели любой текст. Кликни «Добавить выделенное в исключения». **Ожидаемо:** алерт «Не удалось прочитать выделение…», файл не меняется.

- [ ] **Step 9: Регресс — существующий терминальный fallback всё ещё работает**

В Terminal.app с русской раскладкой набери `pkflp ` (опечатка-пример из существующего дизайн-документа `docs/superpowers/specs/2026-08-12-terminal-keystroke-fallback-design.md`, либо любое слово из ambiguous-набора). **Ожидаемо:** поведение идентично до этой задачи — переименование `isTerminalFrontmost` → `usesKeystrokeFallback` не изменило логику.

- [ ] **Step 10: Регистрация гибридного приложения**

Открой любое Electron-приложение, где AX-замена не работает (например VS Code, Slack) — или подтверди на реальном кейсе, если такой под рукой есть. В нём набери слово в неправильной раскладке, доведи до границы — **ожидаемо (до регистрации):** слово НЕ исправляется (AX не сработал, приложение не в списке гибридных).

Переключись на LatCyr → «Добавить текущее приложение как гибридное». **Ожидаемо:** алерт «Добавлено как гибридное: <Имя> (<bundle id>)». Проверь:

```bash
cat "$HOME/Library/Application Support/LatCyr/hybrid-apps.txt"
```

Повтори ввод неправильной раскладки в этом приложении. **Ожидаемо:** теперь слово исправляется через keystroke-fallback (как в терминале).

- [ ] **Step 11: Повторная регистрация — уже поддерживается**

В Terminal.app (уже в жёстко заданном списке) попробуй «Добавить текущее приложение как гибридное». **Ожидаемо:** алерт «Уже поддерживается: Terminal (com.apple.Terminal)», файл `hybrid-apps.txt` не меняется.

- [ ] **Step 12: Перезапуск подхватывает внешние правки**

Останови LatCyr (Выход). Вручную добавь строку `manualword` в `~/Library/Application Support/LatCyr/exceptions.txt` через любой текстовый редактор. Перезапусти `dist/LatCyr.app`. В TextEdit набери и проверь, что `manualword` теперь защищено (используй Step 2-стиль проверку — например, сделай его похожим на акроним, или просто убедись, что добавление того же слова через меню теперь даёт «Уже в списке»).

- [ ] **Step 13: Регрессия юнит-тестов**

```bash
swift test
```

Expected: все тесты (`TextConverterTests`, `LanguageDetectorTests`) зелёные.
