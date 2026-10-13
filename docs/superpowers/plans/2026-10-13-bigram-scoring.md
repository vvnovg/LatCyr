# Биграммный скоринг раскладки — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Заменить побуквенный частотный скоринг в `LanguageDetector.isWrongLayout` на отношение правдоподобий (LLR) двух биграммных моделей — русской и английской — и подтвердить улучшение воспроизводимым замером.

**Architecture:** Новый чистый тип `BigramModel` (таблица log-вероятностей пар букв с маркерами начала и конца слова). Таблицы генерируются одноразовым скриптом из FrequencyWords и встраиваются в Swift-файл. `isWrongLayout` сохраняет проверки до скоринга (длина, символы, исключения, домен); фильтрация пунктуации и три старых порога заменяются пропуском чужих символов самой моделью и порогами, зависящими от длины слова (`llrThresholds`; редакция 2026-10-14, см. спеку 2.3). Отдельный инструмент замера `scripts/eval-detector/main.swift` даёт базовую линию до изменения и цифры после.

**Tech Stack:** Swift 5.9 Package (без Xcode), XCTest, `swiftc` для скриптов, AppKit `NSSpellChecker` только в инструменте замера.

**Spec:** `docs/superpowers/specs/2026-10-13-bigram-scoring-design.md`.

## Global Constraints

- Во время работы приложения ни сети, ни чтения файлов для скоринга: таблицы — Swift-литералы в `Sources/LatCyr/BigramTables.swift`.
- Источник данных: FrequencyWords, коммит `525f9b560de45753a5ea01069454e72e9aa541c6`, файлы `content/2018/ru/ru_50k.txt` (sha256 `6095f507cc167488ec66ada5a85ac50433503a08ad24a07c6eabdf54352c4e7f`) и `content/2018/en/en_50k.txt` (sha256 `5351ff405b1126ef555791dd4d9798a48e3e9a501a9fc481a9da957752cfb458`). Лицензия данных CC BY-SA 4.0 (© Hermit Dave), код — MIT. Сами списки не коммитятся.
- Параметры генератора: слова длиной ≥ 3, «ё»→«е», только буквы алфавита, вес `log(1 + count)`, совместная вероятность по всем переходам, пол `1e-7`, натуральный логарифм; в обучение идут только слова с чётным FNV-1a хешем (64-бит, по UTF-8 байтам нормализованного слова), нечётные — проверочная половина.
- Нельзя «просто понизить порог» ради отдельных слов. Порог выбирается по правилу из Task 4, исключения (`Resources/exceptions.txt`) в этой работе не меняются.
- Поведение, которое не должно меняться: `minWordLength` = 3, проактивные сигналы, `looksLikeDomain`/`knownTLDs`, результат на словах с пунктуацией (`amazon.de`, `объём`, `т.е.`, `j,]trn` — сам механизм `strippingPunctuation` удаляется в Task 4, см. спеку 2.3), `isCarriableFunctionWord`.
- Комментарии в коде — на английском (как во всём `Sources/`), документация в `docs/` и `CLAUDE.md` — на русском.
- Коммиты — conventional style, каждый заканчивается строкой `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Работа идёт на ветке `feat/bigram-scoring`. Все команды выполняются из корня worktree.
- `swift test` должен быть зелёным в конце каждой задачи.

## File Structure

| Файл | Ответственность | Задача |
|---|---|---|
| `Sources/LatCyr/BigramModel.swift` (new) | Чистый тип модели: алфавит, таблица, `averageLogProb` | 1 |
| `Tests/LatCyrTests/BigramModelTests.swift` (new) | Юнит-тесты модели на ручных таблицах + sanity реальных таблиц | 1, 2 |
| `scripts/gen-bigrams.swift` (new) | Генератор таблиц и проверочных половин | 2 |
| `Sources/LatCyr/BigramTables.swift` (new, generated) | `BigramModel.russian`, `BigramModel.english` | 2 |
| `scripts/eval-detector/main.swift` (new) | Инструмент замера | 3, 4 |
| `scripts/eval-data/man-tokens.txt` (new) | Набор A: токены man-страниц | 3 |
| `scripts/eval-data/ru-dict.txt` (new, generated) | Набор D: русские слова из NSSpellChecker | 3 |
| `Sources/LatCyr/LanguageDetector.swift` | LLR вместо старого скоринга | 4 |
| `Tests/LatCyrTests/LanguageDetectorTests.swift` | Перевод тестов на новую шкалу, новые тесты | 4 |
| `docs/superpowers/specs/2026-10-13-bigram-scoring-design.md` | Раздел 7 — результаты | 3, 4 |
| `CLAUDE.md` | Описание нового скоринга, команд и тестов | 5 |

Каталоги вне git (оба покрыты `.gitignore` через `.build/`): `.build/frequencywords/` — скачанные списки; `.build/eval/` — бинарники инструментов, проверочные половины, отчёты.

---

### Task 1: `BigramModel`

**Files:**
- Create: `Sources/LatCyr/BigramModel.swift`
- Test: `Tests/LatCyrTests/BigramModelTests.swift`

**Interfaces:**
- Consumes: ничего.
- Produces:
  - `public struct BigramModel`
  - `public init(alphabet: String, logProbs: [Float])` — `logProbs` построчно, размер `(alphabet.count + 2)²`; индекс 0 — маркер начала `^`, `1...N` — буквы в порядке `alphabet`, `N+1` — маркер конца `$`; строка — первый символ пары, столбец — второй.
  - `public func averageLogProb(_ word: String) -> Double`
  - `public static let floorProbability: Double` (= `1e-7`), `public static let floorLogProb: Double` (= `log(1e-7)`)

- [ ] **Step 1: Write the failing tests**

Create `Tests/LatCyrTests/BigramModelTests.swift`:

```swift
import XCTest
@testable import LatCyr

final class BigramModelTests: XCTestCase {
    /// A model over `alphabet` where every cell is `fill` except `cells`,
    /// given as (from, to, logProb). Index 0 is "^", 1...N the letters,
    /// N+1 is "$" — for alphabet "ab": ^ = 0, a = 1, b = 2, $ = 3.
    private func model(_ cells: [(Int, Int, Float)], alphabet: String = "ab", fill: Float = -10) -> BigramModel {
        let size = alphabet.count + 2
        var table = [Float](repeating: fill, count: size * size)
        for (from, to, value) in cells { table[from * size + to] = value }
        return BigramModel(alphabet: alphabet, logProbs: table)
    }

    // ^a = -1, ab = -2, b$ = -3: three transitions, mean -2.
    func testAveragesEveryTransitionIncludingBoundaries() {
        let m = model([(0, 1, -1), (1, 2, -2), (2, 3, -3)])
        XCTAssertEqual(m.averageLogProb("ab"), -2, accuracy: 1e-9)
    }

    // "a" alone is ^a + a$. Only one of them is cheap in each model, so a
    // model that ignored either marker would score both words -10.
    func testWordStartAndEndAreScored() {
        XCTAssertEqual(model([(0, 1, -1)]).averageLogProb("a"), -5.5, accuracy: 1e-9)
        XCTAssertEqual(model([(1, 3, -1)]).averageLogProb("a"), -5.5, accuracy: 1e-9)
    }

    // The same letters in another order use other cells.
    func testOrderMatters() {
        let m = model([(0, 1, -1), (1, 2, -2), (2, 3, -3)])
        XCTAssertEqual(m.averageLogProb("ba"), -10, accuracy: 1e-9)
    }

    func testCaseInsensitive() {
        let m = model([(0, 1, -1), (1, 2, -2), (2, 3, -3)])
        XCTAssertEqual(m.averageLogProb("AB"), m.averageLogProb("ab"))
    }

    // The apostrophe in "don't" is the "э" key under the English layout;
    // it must neither break the word nor cost a floor-level pair.
    func testCharactersOutsideAlphabetAreSkipped() {
        let m = model([(0, 1, -1), (1, 2, -2), (2, 3, -3)])
        XCTAssertEqual(m.averageLogProb("a'b"), -2, accuracy: 1e-9)
    }

    func testYoFoldsIntoYe() {
        let m = model([(0, 1, -1), (1, 2, -2), (2, 3, -3)], alphabet: "ен")
        XCTAssertEqual(m.averageLogProb("ён"), -2, accuracy: 1e-9)
        XCTAssertEqual(m.averageLogProb("Ён"), -2, accuracy: 1e-9)
    }

    func testWordWithoutAlphabetLettersScoresFloor() {
        let m = model([])
        XCTAssertEqual(m.averageLogProb(""), BigramModel.floorLogProb)
        XCTAssertEqual(m.averageLogProb("'1"), BigramModel.floorLogProb)
    }

    func testFloorIsFinite() {
        XCTAssertTrue(BigramModel.floorLogProb.isFinite)
        XCTAssertEqual(BigramModel.floorLogProb, log(1e-7), accuracy: 1e-12)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BigramModelTests`
Expected: FAIL to compile — `cannot find 'BigramModel' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/LatCyr/BigramModel.swift`:

```swift
import Foundation

/// Letter-bigram model of one language: how plausible a word's letter
/// *pairs* are, word boundaries included.
///
/// Single-letter frequency cannot tell "ашду" (the keys of "file" under the
/// Russian layout) from a Russian word — а, ш, д and у are all ordinary
/// Russian letters. Pairs can: "аш" opens few Russian words and "ду" rarely
/// ends one. The tables live in the generated BigramTables.swift; see
/// scripts/gen-bigrams.swift.
public struct BigramModel {
    /// Probability the generator clamps every cell to from below, so an
    /// impossible pair costs a large but finite penalty, never -infinity.
    public static let floorProbability = 1e-7
    public static let floorLogProb = log(floorProbability)

    private let index: [Character: Int]
    private let size: Int
    private let logProbs: [Float]

    /// - Parameters:
    ///   - alphabet: the model's letters, lowercase, in table order.
    ///   - logProbs: row-major `(alphabet.count + 2)²` natural-log
    ///     probabilities. Index 0 is the word-start marker, 1...N the
    ///     letters in `alphabet` order, N+1 the word-end marker; the row is
    ///     the first character of a pair, the column the second.
    public init(alphabet: String, logProbs: [Float]) {
        let letters = Array(alphabet)
        size = letters.count + 2
        precondition(logProbs.count == size * size, "bigram table must have (alphabet.count + 2)² cells")
        var index: [Character: Int] = [:]
        for (i, letter) in letters.enumerated() { index[letter] = i + 1 }
        self.index = index
        self.logProbs = logProbs
    }

    /// Mean natural-log probability over every transition of "^word$".
    ///
    /// Lowercases and folds "ё" into "е" (the tables are built the same way).
    /// Characters outside the alphabet are skipped and their neighbours
    /// joined directly — the way the old letter-frequency score ignored
    /// them; the apostrophe of "don't" is the case that matters. A word with
    /// no letters of the alphabet at all scores `floorLogProb`.
    public func averageLogProb(_ word: String) -> Double {
        let positions = word.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .compactMap { index[$0] }
        guard !positions.isEmpty else { return Self.floorLogProb }

        var previous = 0
        var sum = 0.0
        for position in positions + [size - 1] {
            sum += Double(logProbs[previous * size + position])
            previous = position
        }
        return sum / Double(positions.count + 1)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BigramModelTests`
Expected: PASS, 8 tests.

Run: `swift test`
Expected: PASS (all existing tests untouched).

- [ ] **Step 5: Commit**

```bash
git add Sources/LatCyr/BigramModel.swift Tests/LatCyrTests/BigramModelTests.swift
git commit -m "feat: add letter-bigram language model

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Генератор и таблицы

**Files:**
- Create: `scripts/gen-bigrams.swift`
- Create (generated): `Sources/LatCyr/BigramTables.swift`
- Modify: `Tests/LatCyrTests/BigramModelTests.swift` (добавить два теста на реальные таблицы)

**Interfaces:**
- Consumes: `BigramModel.init(alphabet:logProbs:)`, `BigramModel.floorLogProb` (Task 1).
- Produces:
  - `static let russian: BigramModel` (алфавит `"абвгдежзийклмнопрстуфхцчшщъыьэюя"`, 34×34) и `static let english: BigramModel` (алфавит `"abcdefghijklmnopqrstuvwxyz"`, 28×28) в `extension BigramModel`.
  - Файлы `.build/eval/ru_holdout.txt` и `.build/eval/en_holdout.txt` (по слову в строке, нормализованные, без повторов) — их читает Task 3.

- [ ] **Step 1: Download the source lists and verify checksums**

```bash
mkdir -p .build/frequencywords .build/eval
curl -sSfL -o .build/frequencywords/ru_50k.txt https://raw.githubusercontent.com/hermitdave/FrequencyWords/525f9b560de45753a5ea01069454e72e9aa541c6/content/2018/ru/ru_50k.txt
curl -sSfL -o .build/frequencywords/en_50k.txt https://raw.githubusercontent.com/hermitdave/FrequencyWords/525f9b560de45753a5ea01069454e72e9aa541c6/content/2018/en/en_50k.txt
printf '%s  %s\n' 6095f507cc167488ec66ada5a85ac50433503a08ad24a07c6eabdf54352c4e7f .build/frequencywords/ru_50k.txt 5351ff405b1126ef555791dd4d9798a48e3e9a501a9fc481a9da957752cfb458 .build/frequencywords/en_50k.txt | shasum -a 256 -c
```

Expected: `.build/frequencywords/ru_50k.txt: OK` и `.build/frequencywords/en_50k.txt: OK`.

- [ ] **Step 2: Write the failing sanity tests for the real tables**

Append to `BigramModelTests` (inside the class):

```swift
    // Sanity checks on the generated tables, not on the detector: a broken
    // generator (transposed rows, wrong alphabet order, conditional instead
    // of joint probabilities) shows up here first. "ашду" is "file" typed
    // under the Russian layout; "ghbdtn" is "привет" typed under the English.
    func testRealTablesSeparateWordsFromLayoutGibberish() {
        XCTAssertGreaterThan(BigramModel.russian.averageLogProb("привет"), BigramModel.russian.averageLogProb("ашду") + 2)
        XCTAssertGreaterThan(BigramModel.english.averageLogProb("hello"), BigramModel.english.averageLogProb("ghbdtn") + 1)
    }

    // Every score stays at or above the floor (the literals are rounded to
    // four decimals, hence the tolerance).
    func testRealTablesStayAboveFloor() {
        for word in ["привет", "ашду", "щщщщ", "ъъъ"] {
            XCTAssertGreaterThanOrEqual(BigramModel.russian.averageLogProb(word), BigramModel.floorLogProb - 1e-3)
        }
        for word in ["hello", "qqqq", "xzxz"] {
            XCTAssertGreaterThanOrEqual(BigramModel.english.averageLogProb(word), BigramModel.floorLogProb - 1e-3)
        }
    }
```

Run: `swift test --filter BigramModelTests`
Expected: FAIL to compile — `type 'BigramModel' has no member 'russian'`.

- [ ] **Step 3: Write the generator**

Create `scripts/gen-bigrams.swift`:

```swift
import Foundation

// Generates Sources/LatCyr/BigramTables.swift from the FrequencyWords lists,
// and writes the held-out halves scripts/eval-detector measures against.
// Design: docs/superpowers/specs/2026-10-13-bigram-scoring-design.md, §3.
//
// Usage (repo root; download commands are in the plan,
// docs/superpowers/plans/2026-10-13-bigram-scoring.md, Task 2):
//   swiftc -O -o .build/gen-bigrams scripts/gen-bigrams.swift
//   .build/gen-bigrams .build/frequencywords/ru_50k.txt .build/frequencywords/en_50k.txt .build/eval > Sources/LatCyr/BigramTables.swift

let sourceCommit = "525f9b560de45753a5ea01069454e72e9aa541c6"
let russianAlphabet = "абвгдежзийклмнопрстуфхцчшщъыьэюя" // "ё" is folded into "е"
let englishAlphabet = "abcdefghijklmnopqrstuvwxyz"
let floorProbability = 1e-7 // must match BigramModel.floorProbability
let minLength = 3

typealias Entry = (word: String, count: Int)

/// 64-bit FNV-1a over UTF-8 bytes — stable across runs and machines, unlike
/// String.hashValue, so the train/holdout split is reproducible.
func fnv1a(_ s: String) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in s.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x100000001b3
    }
    return hash
}

/// Odd-hashed words are held out for scripts/eval-detector; only even-hashed
/// ones train the tables.
func isHoldout(_ word: String) -> Bool { fnv1a(word) % 2 == 1 }

func load(_ path: String, alphabet: String) -> [Entry] {
    let letters = Set(alphabet)
    let text = try! String(contentsOfFile: path, encoding: .utf8)
    var entries: [Entry] = []
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: " ")
        guard parts.count == 2, let count = Int(parts[1]) else { continue }
        let word = parts[0].lowercased().replacingOccurrences(of: "ё", with: "е")
        guard word.count >= minLength, word.allSatisfy({ letters.contains($0) }) else { continue }
        entries.append((word, count))
    }
    return entries
}

/// Joint probability of each pair over all transitions of all "^word$",
/// each word weighted log(1 + count), clamped to the floor, natural log.
func table(_ entries: [Entry], alphabet: String) -> [Float] {
    let letters = Array(alphabet)
    let size = letters.count + 2
    var index: [Character: Int] = [:]
    for (i, letter) in letters.enumerated() { index[letter] = i + 1 }

    var weights = [Double](repeating: 0, count: size * size)
    for (word, count) in entries {
        let weight = log(1 + Double(count))
        var previous = 0
        for position in word.map({ index[$0]! }) + [size - 1] {
            weights[previous * size + position] += weight
            previous = position
        }
    }
    let total = weights.reduce(0, +)
    return weights.map { Float(log(max($0 / total, floorProbability))) }
}

func writeHoldout(_ entries: [Entry], to path: String) -> Int {
    var seen = Set<String>()
    var lines: [String] = []
    for (word, _) in entries where isHoldout(word) && seen.insert(word).inserted {
        lines.append(word)
    }
    try! (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    return lines.count
}

func literal(name: String, alphabet: String, values: [Float]) -> String {
    let labels = ["^"] + alphabet.map(String.init) + ["$"]
    let size = labels.count
    var out = "    static let \(name) = BigramModel(alphabet: \"\(alphabet)\", logProbs: [\n"
    out += "        // columns: \(labels.joined(separator: " "))\n"
    for row in 0..<size {
        let cells = values[row * size..<(row + 1) * size].map { String(format: "%.4f", $0) }
        out += "        " + cells.joined(separator: ", ") + ", // \(labels[row])\n"
    }
    out += "    ])\n"
    return out
}

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write("usage: gen-bigrams <ru_50k.txt> <en_50k.txt> <holdout-dir>\n".data(using: .utf8)!)
    exit(2)
}

let russian = load(args[1], alphabet: russianAlphabet)
let english = load(args[2], alphabet: englishAlphabet)
let russianTrain = russian.filter { !isHoldout($0.word) }
let englishTrain = english.filter { !isHoldout($0.word) }
let russianHeld = writeHoldout(russian, to: args[3] + "/ru_holdout.txt")
let englishHeld = writeHoldout(english, to: args[3] + "/en_holdout.txt")
FileHandle.standardError.write("""
    ru: \(russianTrain.count) train entries, \(russianHeld) holdout words
    en: \(englishTrain.count) train entries, \(englishHeld) holdout words

    """.data(using: .utf8)!)

print("""
// GENERATED by scripts/gen-bigrams.swift — do not edit by hand.
//
// Source: FrequencyWords by Hermit Dave, https://github.com/hermitdave/FrequencyWords
// at commit \(sourceCommit), content/2018/ru/ru_50k.txt and content/2018/en/en_50k.txt.
// Data license: CC BY-SA 4.0 (© Hermit Dave); FrequencyWords code: MIT.
// These tables are aggregate letter-pair statistics derived from those lists.
//
// Parameters: words of \(minLength)+ letters of the alphabet, "ё" folded into "е",
// each word weighted log(1 + count), joint probability over all transitions
// of "^word$", floor \(floorProbability), natural log. Training half only:
// words with an even FNV-1a hash (odd ones are held out for
// scripts/eval-detector).

extension BigramModel {
""")
print(literal(name: "russian", alphabet: russianAlphabet, values: table(russianTrain, alphabet: russianAlphabet)))
print(literal(name: "english", alphabet: englishAlphabet, values: table(englishTrain, alphabet: englishAlphabet)), terminator: "")
print("}")
```

- [ ] **Step 4: Generate the tables**

```bash
swiftc -O -o .build/gen-bigrams scripts/gen-bigrams.swift
.build/gen-bigrams .build/frequencywords/ru_50k.txt .build/frequencywords/en_50k.txt .build/eval > Sources/LatCyr/BigramTables.swift
wc -l Sources/LatCyr/BigramTables.swift .build/eval/ru_holdout.txt .build/eval/en_holdout.txt
```

Expected: stderr печатает примерно по 23–24 тыс. обучающих записей и столько же проверочных слов на язык (прототип: ru 23881/24070, en 23054/23223; точные числа зависят от дедупликации). `BigramTables.swift` — около 85 строк (заголовок + 34 + 28 строк таблиц). Повторный запуск даёт побайтно тот же файл (`git diff --stat` после второго прогона пуст).

- [ ] **Step 5: Run tests**

Run: `swift test --filter BigramModelTests`
Expected: PASS, 10 tests.

Если `testRealTablesSeparateWordsFromLayoutGibberish` падает, ошибка в генераторе (порядок строк и столбцов, алфавит), а не в отступах теста. Прототип давал для «привет» −4.96 и для «ашду» −8.22.

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/gen-bigrams.swift Sources/LatCyr/BigramTables.swift Tests/LatCyrTests/BigramModelTests.swift
git commit -m "feat: generate Russian and English bigram tables from FrequencyWords

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Инструмент замера и базовая линия

Детектор в этой задаче **не меняется**: замер фиксирует поведение текущей эвристики.

**Files:**
- Create: `scripts/eval-detector/main.swift`
- Create: `scripts/eval-data/man-tokens.txt`
- Create (generated): `scripts/eval-data/ru-dict.txt`
- Modify: `docs/superpowers/specs/2026-10-13-bigram-scoring-design.md` (раздел 7)

**Interfaces:**
- Consumes: `LanguageDetector.isWrongLayout(word:currentLayoutIsRussian:exceptions:variant:)`, `TextConverter.toCyrillic/toLatin`, файлы `.build/eval/{ru,en}_holdout.txt` (Task 2).
- Produces:
  - Инструмент `.build/eval/eval-detector` с режимами `report`, `words`, `flagged`, `build-ru-dict`. В Task 4 добавятся режим `curve` и вывод LLR в `words`.
  - Функция `report(paths: ReportPaths, decide: Decide)`, где `typealias Decide = (_ typed: String, _ russianActive: Bool, _ variant: TextConverter.RussianKeyboardVariant) -> Bool`. Task 4 вызывает её с другим `decide`.
  - Замороженный бинарник базовой линии `.build/eval/baseline` и отчёт `.build/eval/baseline-report.txt`.

- [ ] **Step 1: Copy the man-page token list (set A)**

Список лежит в основной рабочей копии, в игнорируемом git'ом каталоге probe. В репозиторий кладём только слова, без счётчиков:

```bash
mkdir -p scripts/eval-data
awk '{print $2}' /Users/vvnovg/projects/LatCyr/.superpowers/sdd/bigram-probe/cands.txt > scripts/eval-data/man-tokens.txt
wc -l scripts/eval-data/man-tokens.txt
head -3 scripts/eval-data/man-tokens.txt
```

Expected: `7301`; первые строки — частые токены man-страниц (например, `the`, `and`, `for` — в зависимости от сортировки исходного файла).

- [ ] **Step 2: Write the eval tool**

Create `scripts/eval-detector/main.swift`:

```swift
import AppKit

// eval-detector — measures LanguageDetector.isWrongLayout on word lists with
// no exceptions (the raw detector). Design:
// docs/superpowers/specs/2026-10-13-bigram-scoring-design.md, §5.
//
// Build (repo root; the file must be named main.swift — swiftc only allows
// top-level code there):
//   mkdir -p .build/eval
//   swiftc -O -o .build/eval/eval-detector Sources/LatCyr/LanguageDetector.swift Sources/LatCyr/TextConverter.swift Sources/LatCyr/BigramModel.swift Sources/LatCyr/BigramTables.swift scripts/eval-detector/main.swift
//
// Modes:
//   report <man-tokens.txt> <ru-dict.txt> <ru_holdout.txt> <en_holdout.txt> <exceptions.txt>
//   words <ru|en> <word>...       decision for each word as typed, "ru"/"en" = active layout
//   flagged <ru|en> <list.txt>    words of the list flagged as typed (false-positive dump)
//   build-ru-dict <out.txt>       set D: Russian words from NSSpellChecker completions

typealias Variant = TextConverter.RussianKeyboardVariant
typealias Decide = (_ typed: String, _ russianActive: Bool, _ variant: Variant) -> Bool

struct ReportPaths {
    let manTokens, ruDict, ruHoldout, enHoldout, exceptions: String
}

let variants: [Variant] = [.pc, .apple]
let checker = NSSpellChecker.shared

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

func readWords(_ path: String) -> [String] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
    return text.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

func isWord(_ word: String, language: String) -> Bool {
    checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                          inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
}

let detector: Decide = { typed, russianActive, variant in
    LanguageDetector.isWrongLayout(word: typed, currentLayoutIsRussian: russianActive, exceptions: [], variant: variant)
}

func row(_ label: String, _ variant: Variant, _ hits: Int, _ total: Int) {
    let percent = total == 0 ? 0 : 100 * Double(hits) / Double(total)
    print(label.padding(toLength: 50, withPad: " ", startingAt: 0)
          + "\(variant)".padding(toLength: 7, withPad: " ", startingAt: 0)
          + String(format: "%6d / %6d  %6.2f%%", hits, total, percent))
}

func count(_ words: [String], _ typed: (String) -> String, russianActive: Bool, _ variant: Variant, _ decide: Decide) -> Int {
    words.filter { decide(typed($0), russianActive, variant) }.count
}

func report(paths: ReportPaths, decide: Decide) {
    precondition(isWord("привет", language: "ru") && !isWord("ашду", language: "ru"), "Russian spell checking unavailable")
    precondition(isWord("file", language: "en") && !isWord("afqk", language: "en"), "English spell checking unavailable")

    let man = readWords(paths.manTokens).filter { $0.count >= 3 && $0.allSatisfy { $0.isASCII && $0.isLetter } }
    let manReal = man.filter { isWord($0, language: "en") && !isWord(TextConverter.toCyrillic($0, variant: .pc), language: "ru") }
    let ruHoldout = readWords(paths.ruHoldout)
    let enHoldout = readWords(paths.enHoldout)
    let ruDict = readWords(paths.ruDict)
    let latinExceptions = readWords(paths.exceptions).filter { $0.allSatisfy { $0.isASCII && $0.isLetter } }

    for v in variants {
        let cyr: (String) -> String = { TextConverter.toCyrillic($0, variant: v) }
        let lat: (String) -> String = { TextConverter.toLatin($0, variant: v) }
        let same: (String) -> String = { $0 }
        row("A  man tokens typed in RU layout: caught", v, count(man, cyr, russianActive: true, v, decide), man.count)
        row("A' real EN man words typed in RU layout: caught", v, count(manReal, cyr, russianActive: true, v, decide), manReal.count)
        row("B  ru holdout typed in EN layout: caught", v, count(ruHoldout, lat, russianActive: false, v, decide), ruHoldout.count)
        row("B  ru holdout typed correctly: FALSE POSITIVE", v, count(ruHoldout, same, russianActive: true, v, decide), ruHoldout.count)
        row("C  en holdout typed in RU layout: caught", v, count(enHoldout, cyr, russianActive: true, v, decide), enHoldout.count)
        row("C  en holdout typed correctly: FALSE POSITIVE", v, count(enHoldout, same, russianActive: false, v, decide), enHoldout.count)
        row("D  ru spell-checker dict typed correctly: FALSE POS", v, count(ruDict, same, russianActive: true, v, decide), ruDict.count)
        row("E  Latin bundled exceptions typed in RU: caught raw", v, count(latinExceptions, cyr, russianActive: true, v, decide), latinExceptions.count)
    }
}

func activeLayout(_ arg: String) -> Bool {
    switch arg {
    case "ru": return true
    case "en": return false
    default: fail("layout must be ru or en, got \(arg)")
    }
}

func words(russianActive: Bool, _ list: [String]) {
    for word in list {
        let decisions = variants.map { "\($0)=\(detector(word, russianActive, $0))" }
        print("\(word)\t\(decisions.joined(separator: " "))")
    }
}

func flagged(russianActive: Bool, path: String) {
    for word in readWords(path) {
        let hit = variants.filter { detector(word, russianActive, $0) }
        if !hit.isEmpty { print("\(word)\t\(hit.map { "\($0)" }.joined(separator: ","))") }
    }
}

func buildRussianDictionary(out: String) {
    let alphabet = Array("абвгдежзийклмнопрстуфхцчшщъыьэюя")
    let cyrillic = Set(alphabet + ["ё"])
    var found = Set<String>()
    for a in alphabet { for b in alphabet { for c in alphabet {
        let prefix = String([a, b, c])
        let completions = checker.completions(forPartialWordRange: NSRange(location: 0, length: 3), in: prefix,
                                              language: "ru", inSpellDocumentWithTag: 0) ?? []
        for completion in completions {
            let word = completion.lowercased()
            if word.count >= 3, word.allSatisfy({ cyrillic.contains($0) }) { found.insert(word) }
        }
    } } }
    try! (found.sorted().joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
    FileHandle.standardError.write("\(found.count) words\n".data(using: .utf8)!)
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "report" where args.count == 7:
    report(paths: ReportPaths(manTokens: args[2], ruDict: args[3], ruHoldout: args[4], enHoldout: args[5], exceptions: args[6]),
           decide: detector)
case "words" where args.count >= 4:
    words(russianActive: activeLayout(args[2]), Array(args[3...]))
case "flagged" where args.count == 4:
    flagged(russianActive: activeLayout(args[2]), path: args[3])
case "build-ru-dict" where args.count == 3:
    buildRussianDictionary(out: args[2])
default:
    fail("usage: see the header of scripts/eval-detector/main.swift")
}
```

- [ ] **Step 3: Build and smoke-test**

```bash
mkdir -p .build/eval
swiftc -O -o .build/eval/eval-detector Sources/LatCyr/LanguageDetector.swift Sources/LatCyr/TextConverter.swift Sources/LatCyr/BigramModel.swift Sources/LatCyr/BigramTables.swift scripts/eval-detector/main.swift
.build/eval/eval-detector words ru ашду руддщ привет
.build/eval/eval-detector words en ghbdtn hello
```

Expected (текущая эвристика):
```
ашду	pc=false apple=false
руддщ	pc=true apple=true
привет	pc=false apple=false
ghbdtn	pc=true apple=true
hello	pc=false apple=false
```

- [ ] **Step 4: Build set D (Russian words from the spell checker)**

```bash
.build/eval/eval-detector build-ru-dict scripts/eval-data/ru-dict.txt
wc -l scripts/eval-data/ru-dict.txt
```

Expected: около 30–60 тыс. слов, работает порядка минуты (32³ запросов к NSSpellChecker). Если слов меньше 10 тыс., русская проверка орфографии в системе не включена — остановиться и сообщить.

- [ ] **Step 5: Freeze the baseline**

```bash
cp .build/eval/eval-detector .build/eval/baseline
.build/eval/baseline report scripts/eval-data/man-tokens.txt scripts/eval-data/ru-dict.txt .build/eval/ru_holdout.txt .build/eval/en_holdout.txt Resources/exceptions.txt | tee .build/eval/baseline-report.txt
```

Expected: 16 строк (8 метрик × 2 варианта). Ориентиры: `A'` ловится примерно на 2186 слов меньше, чем его объём (исходный probe), `E` близок к 0% (бандловые исключения отобраны как раз из пропусков), `B`/`C` FALSE POSITIVE — порядка 1% (прототип: 1.42% / 0.93%).

- [ ] **Step 6: Record the baseline in the spec**

В `docs/superpowers/specs/2026-10-13-bigram-scoring-design.md` заменить строку-заглушку раздела 7 (начинается с `_Заполняется при реализации`) на:

````markdown
### 7.1 Базовая линия (текущая эвристика, до изменения)

Коммит детектора: <вывод `git rev-parse --short HEAD`>. Команда:

```bash
.build/eval/baseline report scripts/eval-data/man-tokens.txt scripts/eval-data/ru-dict.txt .build/eval/ru_holdout.txt .build/eval/en_holdout.txt Resources/exceptions.txt
```

```
<полное содержимое .build/eval/baseline-report.txt>
```

### 7.2 После

_Заполняется в Task 4 плана реализации._
````

Угловые скобки здесь — подстановка вывода команды, не текст. В спеке должен оказаться реальный хеш и реальный отчёт.

- [ ] **Step 7: Run tests and commit**

Run: `swift test`
Expected: PASS (код приложения не менялся).

```bash
git add scripts/eval-detector/main.swift scripts/eval-data/man-tokens.txt scripts/eval-data/ru-dict.txt docs/superpowers/specs/2026-10-13-bigram-scoring-design.md
git commit -m "test: add detector evaluation tool and record the baseline

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: LLR-решение в `LanguageDetector` (редакция 2026-10-14)

> Первая попытка этой задачи остановилась на BLOCKED: см. спеку, раздел 2.3. Эта редакция заменяет её целиком. Изменения: оригинал не фильтруется (`strippingPunctuation` удаляется), пороги зависят от длины слова (`LLRThresholds`), инструмент замера получает частотные строки, набор Y (слова с «ё») и сетку порогов с автоматической проверкой критериев. Базовая линия пересоздаётся расширенным инструментом.

**Files:**
- Modify: `scripts/eval-detector/main.swift` (полная замена)
- Modify: `Sources/LatCyr/LanguageDetector.swift`
- Modify: `Tests/LatCyrTests/LanguageDetectorTests.swift`
- Modify: `docs/superpowers/specs/2026-10-13-bigram-scoring-design.md` (разделы 7.1 и 7.2, статус)

**Interfaces:**
- Consumes: `BigramModel.russian`, `BigramModel.english`, `averageLogProb` (Tasks 1–2); `.build/eval/{ru,en}_holdout.txt` (Task 2); `.build/frequencywords/{ru,en}_50k.txt` (скачаны в Task 2; если их нет — повторить Task 2 Step 1); `scripts/eval-data/*.txt` (Task 3).
- Produces:
  - `public struct LanguageDetector.LLRThresholds: Equatable` с полями `threeLetters`, `fourLetters`, `longer: Double`, `init(threeLetters:fourLetters:longer:)`, `static func uniform(_ value: Double) -> LLRThresholds`, `func threshold(forLength length: Int) -> Double` (≤ 3 → `threeLetters`, 4 → `fourLetters`, ≥ 5 → `longer`).
  - `public static let llrThresholds: LLRThresholds`.
  - `public static func isWrongLayout(word: String, currentLayoutIsRussian: Bool, exceptions: Set<String>, variant: TextConverter.RussianKeyboardVariant, thresholds: LLRThresholds = LanguageDetector.llrThresholds) -> Bool` — существующие вызовы компилируются без изменений.
  - `public static func wrongLayoutLLR(word: String, currentLayoutIsRussian: Bool, variant: TextConverter.RussianKeyboardVariant) -> Double?`.
  - `russianScore(_:)` / `englishScore(_:)` — те же сигнатуры, новая шкала.
  - Удалены: `russianThreshold`, `englishThreshold`, `diffThreshold`, `strippingPunctuation`.
  - Инструмент: режимы `report`, `metrics`, `curve`, `words`, `flagged`, `build-ru-dict`; бинарники `.build/eval/baseline` (старый детектор) и `.build/eval/eval-detector` (новый); файлы `.build/eval/baseline-report.txt`, `.build/eval/baseline-metrics.tsv`, `.build/eval/curve.tsv`, `.build/eval/after-report.txt`.

- [ ] **Step 1: Replace the eval tool**

Проверить, что рабочее дерево чистое (`git status --short` показывает только `?? .superpowers/`). Детектор на этом шаге ещё старый.

Replace the whole of `scripts/eval-detector/main.swift` with:

```swift
import AppKit

// eval-detector — measures LanguageDetector.isWrongLayout on word lists with
// no exceptions (the raw detector). Design:
// docs/superpowers/specs/2026-10-13-bigram-scoring-design.md, §5–§6.
//
// Build (repo root; the file must be named main.swift — swiftc only allows
// top-level code there):
//   mkdir -p .build/eval
//   swiftc -O -o .build/eval/eval-detector Sources/LatCyr/LanguageDetector.swift Sources/LatCyr/TextConverter.swift Sources/LatCyr/BigramModel.swift Sources/LatCyr/BigramTables.swift scripts/eval-detector/main.swift
// The baseline build compiles the pre-bigram LanguageDetector.swift with
// -D BASELINE, which leaves out what needs the new API (LLR, thresholds).
//
// <data> below stands for seven paths:
//   <man-tokens.txt> <ru-dict.txt> <ru_holdout.txt> <en_holdout.txt> <exceptions.txt> <ru_50k.txt> <en_50k.txt>
//
// Modes:
//   report <data>                        full table, both variants
//   metrics <data>                       the pc metrics as two TSV lines (keys, values) — input to curve
//   curve <data> <baseline-metrics.tsv>  threshold grid, one TSV line per combination
//   words <ru|en> <word>...              decision and LLR per word as typed; ru/en = active layout
//   flagged <ru|en> <list.txt>           words of the list flagged as typed (false-positive dump)
//   build-ru-dict <out.txt>              set D: Russian words from NSSpellChecker completions

typealias Variant = TextConverter.RussianKeyboardVariant
typealias Decide = (_ typed: String, _ russianActive: Bool, _ variant: Variant) -> Bool

let variants: [Variant] = [.pc, .apple]
let checker = NSSpellChecker.shared

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

func readLines(_ path: String) -> [String] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
    return text.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

/// One word per line, lowercased.
func readWords(_ path: String) -> [String] { readLines(path).map { $0.lowercased() } }

/// The same normalization the generator applies to the FrequencyWords lists.
func normalized(_ word: String) -> String {
    word.lowercased().replacingOccurrences(of: "ё", with: "е")
}

/// Token counts from a FrequencyWords list ("word count" per line), keyed by
/// the normalized word; counts of words that normalize together are summed.
func readCounts(_ path: String) -> [String: Double] {
    var counts: [String: Double] = [:]
    for line in readLines(path) {
        let parts = line.split(separator: " ")
        guard parts.count == 2, let count = Double(parts[1]) else { continue }
        counts[normalized(String(parts[0])), default: 0] += count
    }
    return counts
}

func isWord(_ word: String, language: String) -> Bool {
    checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                          inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
}

let detector: Decide = { typed, russianActive, variant in
    LanguageDetector.isWrongLayout(word: typed, currentLayoutIsRussian: russianActive, exceptions: [], variant: variant)
}

struct Rate {
    var hits = 0.0
    var total = 0.0
    var percent: Double { total == 0 ? 0 : 100 * hits / total }
}

/// Every metric of the spec's §5, in report order: `metricKeys` names the
/// TSV columns of `metrics`/`curve`, `metricLabels` the rows of `report`.
let metricKeys = ["A", "A'", "B-caught", "B-FP", "C-caught", "C-FP", "D-FP", "E", "Y-FP",
                  "B-caught-w", "B-FP-w", "C-caught-w", "C-FP-w"]
let metricLabels = [
    "A  man tokens typed in RU layout: caught",
    "A' real EN man words typed in RU layout: caught",
    "B  ru holdout typed in EN layout: caught",
    "B  ru holdout typed correctly: FALSE POSITIVE",
    "C  en holdout typed in RU layout: caught",
    "C  en holdout typed correctly: FALSE POSITIVE",
    "D  ru spell-checker dict typed correctly: FALSE POS",
    "E  Latin bundled exceptions typed in RU: caught raw",
    "Y  ru words with ё typed correctly: FALSE POSITIVE",
    "Bw ru holdout typed in EN layout: caught, by tokens",
    "Bw ru holdout typed correctly: FALSE POS, by tokens",
    "Cw en holdout typed in RU layout: caught, by tokens",
    "Cw en holdout typed correctly: FALSE POS, by tokens",
]

struct EvalData {
    let man, manReal, ruHoldout, enHoldout, ruDict, latinExceptions, yoWords: [String]
    let ruCounts, enCounts: [String: Double]

    init(_ paths: [String]) {
        guard paths.count == 7 else { fail("expected 7 data paths, got \(paths.count)") }
        precondition(isWord("привет", language: "ru") && !isWord("ашду", language: "ru"), "Russian spell checking unavailable")
        precondition(isWord("file", language: "en") && !isWord("afqk", language: "en"), "English spell checking unavailable")

        man = readWords(paths[0]).filter { $0.count >= 3 && $0.allSatisfy { $0.isASCII && $0.isLetter } }
        manReal = man.filter { isWord($0, language: "en") && !isWord(TextConverter.toCyrillic($0, variant: .pc), language: "ru") }
        ruDict = readWords(paths[1])
        ruHoldout = readWords(paths[2])
        enHoldout = readWords(paths[3])
        latinExceptions = readWords(paths[4]).filter { $0.allSatisfy { $0.isASCII && $0.isLetter } }
        let cyrillic = Set("абвгдежзийклмнопрстуфхцчшщъыьэюяё")
        yoWords = readLines(paths[5])
            .compactMap { $0.split(separator: " ").first.map { $0.lowercased() } }
            .filter { $0.count >= 3 && $0.contains("ё") && $0.allSatisfy { cyrillic.contains($0) } }
        ruCounts = readCounts(paths[5])
        enCounts = readCounts(paths[6])
    }
}

func rate(_ words: [String], weights: [String: Double]? = nil, typed: (String) -> String,
          russianActive: Bool, _ variant: Variant, _ decide: Decide) -> Rate {
    var result = Rate()
    for word in words {
        let weight = weights.map { $0[word] ?? 0 } ?? 1
        result.total += weight
        if weight > 0 && decide(typed(word), russianActive, variant) { result.hits += weight }
    }
    return result
}

func measure(_ d: EvalData, _ v: Variant, _ decide: Decide) -> [Rate] {
    let cyr: (String) -> String = { TextConverter.toCyrillic($0, variant: v) }
    let lat: (String) -> String = { TextConverter.toLatin($0, variant: v) }
    let same: (String) -> String = { $0 }
    return [
        rate(d.man, typed: cyr, russianActive: true, v, decide),
        rate(d.manReal, typed: cyr, russianActive: true, v, decide),
        rate(d.ruHoldout, typed: lat, russianActive: false, v, decide),
        rate(d.ruHoldout, typed: same, russianActive: true, v, decide),
        rate(d.enHoldout, typed: cyr, russianActive: true, v, decide),
        rate(d.enHoldout, typed: same, russianActive: false, v, decide),
        rate(d.ruDict, typed: same, russianActive: true, v, decide),
        rate(d.latinExceptions, typed: cyr, russianActive: true, v, decide),
        rate(d.yoWords, typed: same, russianActive: true, v, decide),
        rate(d.ruHoldout, weights: d.ruCounts, typed: lat, russianActive: false, v, decide),
        rate(d.ruHoldout, weights: d.ruCounts, typed: same, russianActive: true, v, decide),
        rate(d.enHoldout, weights: d.enCounts, typed: cyr, russianActive: true, v, decide),
        rate(d.enHoldout, weights: d.enCounts, typed: same, russianActive: false, v, decide),
    ]
}

func report(_ d: EvalData, _ decide: Decide) {
    for v in variants {
        for (label, r) in zip(metricLabels, measure(d, v, decide)) {
            print(label.padding(toLength: 56, withPad: " ", startingAt: 0)
                  + "\(v)".padding(toLength: 7, withPad: " ", startingAt: 0)
                  + String(format: "%11.0f / %11.0f  %6.2f%%", r.hits, r.total, r.percent))
        }
    }
}

/// Percentages are compared at the precision `metrics` prints them, so a
/// value equal to the baseline reads back as equal.
func rounded(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }

func metricsLine(_ rates: [Rate]) -> [String: Double] {
    Dictionary(uniqueKeysWithValues: zip(metricKeys, rates.map { rounded($0.percent) }))
}

func printMetrics(_ d: EvalData) {
    let m = metricsLine(measure(d, .pc, detector))
    print(metricKeys.joined(separator: "\t"))
    print(metricKeys.map { String(format: "%.4f", m[$0]!) }.joined(separator: "\t"))
}

func readBaselineMetrics(_ path: String) -> [String: Double] {
    let lines = readLines(path)
    guard lines.count == 2 else { fail("\(path): expected a header and a values line") }
    let keys = lines[0].split(separator: "\t").map(String.init)
    let values = lines[1].split(separator: "\t").compactMap { Double($0) }
    guard keys == metricKeys, values.count == keys.count else { fail("\(path): columns do not match \(metricKeys)") }
    return Dictionary(uniqueKeysWithValues: zip(keys, values))
}

/// The spec's §6 criteria 1–3 against the baseline.
func admissible(_ m: [String: Double], baseline b: [String: Double]) -> Bool {
    let notAbove = ["B-FP", "C-FP", "D-FP", "Y-FP", "B-FP-w", "C-FP-w"]
    let missedHalved = ["A'", "C-caught"]
    let notBelow = ["B-caught", "B-caught-w", "C-caught-w"]
    return notAbove.allSatisfy { m[$0]! <= b[$0]! }
        && missedHalved.allSatisfy { 100 - m[$0]! <= (100 - b[$0]!) / 2 }
        && notBelow.allSatisfy { m[$0]! >= b[$0]! }
}

#if BASELINE
func llrText(_ word: String, _ russianActive: Bool, _ variant: Variant) -> String { "n/a" }

func curve(_ d: EvalData, baseline: [String: Double]) { fail("curve needs the bigram detector; not available with -D BASELINE") }
#else
func llrText(_ word: String, _ russianActive: Bool, _ variant: Variant) -> String {
    LanguageDetector.wrongLayoutLLR(word: word, currentLayoutIsRussian: russianActive, variant: variant)
        .map { String(format: "%.2f", $0) } ?? "n/a"
}

/// Every (three-letter, four-letter, longer) combination with
/// threeLetters >= fourLetters >= longer, measured on the pc variant (the
/// variants agree on every row — see the spec's §7.1).
func curve(_ d: EvalData, baseline: [String: Double]) {
    let threeLetterGrid = [1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0]
    let fourLetterGrid = [1.0, 1.25, 1.5, 1.75, 2.0, 2.25]
    let longerGrid = [0.5, 0.75, 1.0, 1.25, 1.5]
    print((["t3", "t4", "t5"] + metricKeys + ["admissible"]).joined(separator: "\t"))
    for t3 in threeLetterGrid {
        for t4 in fourLetterGrid where t4 <= t3 {
            for t5 in longerGrid where t5 <= t4 {
                let thresholds = LanguageDetector.LLRThresholds(threeLetters: t3, fourLetters: t4, longer: t5)
                let decide: Decide = { typed, russianActive, variant in
                    LanguageDetector.isWrongLayout(word: typed, currentLayoutIsRussian: russianActive, exceptions: [],
                                                   variant: variant, thresholds: thresholds)
                }
                let m = metricsLine(measure(d, .pc, decide))
                let cells = [t3, t4, t5].map { String(format: "%.2f", $0) }
                    + metricKeys.map { String(format: "%.4f", m[$0]!) }
                    + [admissible(m, baseline: baseline) ? "yes" : "no"]
                print(cells.joined(separator: "\t"))
            }
        }
    }
}
#endif

func activeLayout(_ arg: String) -> Bool {
    switch arg {
    case "ru": return true
    case "en": return false
    default: fail("layout must be ru or en, got \(arg)")
    }
}

func words(russianActive: Bool, _ list: [String]) {
    for word in list {
        let decisions = variants.map { "\($0)=\(detector(word, russianActive, $0)) llr=\(llrText(word, russianActive, $0))" }
        print("\(word)\t\(decisions.joined(separator: "  "))")
    }
}

func flagged(russianActive: Bool, path: String) {
    for word in readWords(path) {
        let hit = variants.filter { detector(word, russianActive, $0) }
        if !hit.isEmpty { print("\(word)\t\(hit.map { "\($0)" }.joined(separator: ","))") }
    }
}

func buildRussianDictionary(out: String) {
    let alphabet = Array("абвгдежзийклмнопрстуфхцчшщъыьэюя")
    let cyrillic = Set(alphabet + ["ё"])
    var found = Set<String>()
    for a in alphabet { for b in alphabet { for c in alphabet {
        let prefix = String([a, b, c])
        let completions = checker.completions(forPartialWordRange: NSRange(location: 0, length: 3), in: prefix,
                                              language: "ru", inSpellDocumentWithTag: 0) ?? []
        for completion in completions {
            let word = completion.lowercased()
            if word.count >= 3, word.allSatisfy({ cyrillic.contains($0) }) { found.insert(word) }
        }
    } } }
    try! (found.sorted().joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
    FileHandle.standardError.write("\(found.count) words\n".data(using: .utf8)!)
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "report" where args.count == 9:
    report(EvalData(Array(args[2...8])), detector)
case "metrics" where args.count == 9:
    printMetrics(EvalData(Array(args[2...8])))
case "curve" where args.count == 10:
    curve(EvalData(Array(args[2...8])), baseline: readBaselineMetrics(args[9]))
case "words" where args.count >= 4:
    words(russianActive: activeLayout(args[2]), Array(args[3...]))
case "flagged" where args.count == 4:
    flagged(russianActive: activeLayout(args[2]), path: args[3])
case "build-ru-dict" where args.count == 3:
    buildRussianDictionary(out: args[2])
default:
    fail("usage: see the header of scripts/eval-detector/main.swift")
}
```

- [ ] **Step 2: Rebuild the baseline with the extended tool**

Детектор ещё старый, поэтому базовая линия собирается из текущего `LanguageDetector.swift` с флагом `-D BASELINE`:

```bash
D="scripts/eval-data/man-tokens.txt scripts/eval-data/ru-dict.txt .build/eval/ru_holdout.txt .build/eval/en_holdout.txt Resources/exceptions.txt .build/frequencywords/ru_50k.txt .build/frequencywords/en_50k.txt"
swiftc -O -D BASELINE -o .build/eval/baseline Sources/LatCyr/LanguageDetector.swift Sources/LatCyr/TextConverter.swift Sources/LatCyr/BigramModel.swift Sources/LatCyr/BigramTables.swift scripts/eval-detector/main.swift
.build/eval/baseline report $D | tee .build/eval/baseline-report.txt
.build/eval/baseline metrics $D | tee .build/eval/baseline-metrics.tsv
.build/eval/baseline words ru ашду привет
```

Expected:
- `baseline-report.txt` — 26 строк (13 метрик × 2 варианта). Строки A, A', B, C, D, E совпадают по числам с разделом 7.1 спеки (A' = 2982 / 5185 = 57.51%, B FALSE POSITIVE = 351 / 23689 = 1.48%, C caught = 60.85%, D = 976 / 53035 = 1.84%). Если хоть одно из этих чисел отличается — остановиться и доложить.
- Y — около 823 слов, ложных порядка 34 (оценка контроллера).
- `baseline-metrics.tsv` — две строки по 13 колонок.
- `words` печатает `ашду	pc=false llr=n/a  apple=false llr=n/a` и `привет	pc=false llr=n/a  apple=false llr=n/a`.

Сборка без `-D BASELINE` на этом шаге **ожидаемо не компилируется** (нет `LLRThresholds`/`wrongLayoutLLR`) — её не запускать до Step 4.

В спеке, в разделе `### 7.1 Базовая линия (текущая эвристика, до изменения)`:
- удалить строку-пометку `_Пересоздаётся в Task 4 расширенным инструментом…_`;
- заменить строку `Коммит детектора: …` на `Коммит детектора: <git rev-parse --short HEAD>. Инструмент — редакция с частотными строками и набором Y (Task 4). Команды:`;
- заменить блок команды на:

````markdown
```bash
D="scripts/eval-data/man-tokens.txt scripts/eval-data/ru-dict.txt .build/eval/ru_holdout.txt .build/eval/en_holdout.txt Resources/exceptions.txt .build/frequencywords/ru_50k.txt .build/frequencywords/en_50k.txt"
.build/eval/baseline report $D
.build/eval/baseline metrics $D
```
````

- заменить блок отчёта на полное содержимое `.build/eval/baseline-report.txt`, а сразу после него добавить блок с содержимым `.build/eval/baseline-metrics.tsv`;
- абзац «Варианты `pc` и `apple` совпадают…» оставить.

Угловые скобки — подстановка вывода команды.

Run: `swift test`
Expected: PASS (детектор не менялся).

```bash
git add scripts/eval-detector/main.swift docs/superpowers/specs/2026-10-13-bigram-scoring-design.md
git commit -m "test: weight the detector evaluation by token frequency and add a threshold grid

Adds frequency-weighted rows, a set of words with ё and a curve over
per-length thresholds checked against the baseline criteria. The
baseline is re-recorded with the extended tool.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 3: Write the new failing tests**

Add to `LanguageDetectorTests` (inside the class):

```swift
    // The motivating misses: frequent English words typed under the Russian
    // layout whose Cyrillic form is made of frequent Russian letters. The
    // letter-frequency score held all of them over the old 0.4 threshold
    // ("ашду" 0.463, "ершы" 0.483, "ащк" 0.527); letter pairs give them
    // away. No exceptions — the bundled list must not be what catches them.
    func testFrequentEnglishWordsCaughtWithoutExceptions() {
        for typed in ["ашду", "ершы", "ащк", "цшер", "фку", "ерфе"] { // file this for with are that
            for variant in [TextConverter.RussianKeyboardVariant.pc, .apple] {
                XCTAssertTrue(LanguageDetector.isWrongLayout(word: typed, currentLayoutIsRussian: true, exceptions: [], variant: variant),
                              "\(typed) (\(variant)) not corrected")
            }
        }
    }

    // Correct Russian words built from rare pairs (щ, ъ, ы, э). These are
    // where a bigram model is most likely to misfire.
    func testRussianWordsWithRarePairsNotTouched() {
        for word in ["шею", "щука", "съезд", "объект", "этот", "мысль", "вообще", "подъезд",
                     "взгляд", "чувство", "следующий", "объявление", "здравствуйте"] {
            for variant in [TextConverter.RussianKeyboardVariant.pc, .apple] {
                XCTAssertFalse(LanguageDetector.isWrongLayout(word: word, currentLayoutIsRussian: true, exceptions: [], variant: variant),
                               "\(word) (\(variant)) wrongly corrected")
            }
        }
    }

    // The most frequent Russian words whose letters sit on punctuation keys
    // (б, ю, ж, ё) or map to English vowels (у, ы, е). Scoring them with
    // those letters cut out ("был" as "ыл", "ещё" as "ещ") flagged them —
    // the original is scored whole. Several were also false positives of
    // the old letter-frequency score ("уже", "еще", "хочу", "ему", "буду").
    func testFrequentRussianWordsNotTouched() {
        for word in ["был", "быть", "была", "были", "уже", "ещё", "еще", "тут", "лучше",
                     "хочу", "ему", "буду", "друг", "будет", "может", "между"] {
            for variant in [TextConverter.RussianKeyboardVariant.pc, .apple] {
                XCTAssertFalse(LanguageDetector.isWrongLayout(word: word, currentLayoutIsRussian: true, exceptions: [], variant: variant),
                               "\(word) (\(variant)) wrongly corrected")
            }
        }
    }

    // Short English and command-line tokens typed correctly. Several are
    // barely English as letter sequences — exactly why thresholds must not
    // simply be lowered.
    func testShortEnglishTokensNotTouched() {
        for word in ["the", "and", "npm", "git", "ssh", "sudo", "grep", "brew", "http", "www", "usb", "json", "yaml", "mkdir", "chmod"] {
            for variant in [TextConverter.RussianKeyboardVariant.pc, .apple] {
                XCTAssertFalse(LanguageDetector.isWrongLayout(word: word, currentLayoutIsRussian: false, exceptions: [], variant: variant),
                               "\(word) (\(variant)) wrongly corrected")
            }
        }
    }

    // The score half alone: guards still apply, exceptions and domains do not.
    func testWrongLayoutLLR() {
        XCTAssertNil(LanguageDetector.wrongLayoutLLR(word: "gh", currentLayoutIsRussian: false, variant: .pc))
        XCTAssertNil(LanguageDetector.wrongLayoutLLR(word: "ghbdtn1", currentLayoutIsRussian: false, variant: .pc))
        let wrong = LanguageDetector.wrongLayoutLLR(word: "ghbdtn", currentLayoutIsRussian: false, variant: .pc)!
        let right = LanguageDetector.wrongLayoutLLR(word: "hello", currentLayoutIsRussian: false, variant: .pc)!
        XCTAssertGreaterThan(wrong, LanguageDetector.llrThresholds.longer)
        XCTAssertLessThan(right, LanguageDetector.llrThresholds.longer)
    }

    // Explicit thresholds override the defaults — the evaluation tool
    // sweeps them to draw its grid.
    func testExplicitThresholds() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ghbdtn", currentLayoutIsRussian: false, exceptions: [], variant: .pc, thresholds: .uniform(-100)))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "ghbdtn", currentLayoutIsRussian: false, exceptions: [], variant: .pc, thresholds: .uniform(100)))
    }

    // A three-letter word gives the model four transitions to judge, so its
    // LLR is noisy ("тут" scores well above many genuine misses) and needs
    // the widest margin; the margin narrows as words get longer.
    func testThresholdsByLength() {
        let t = LanguageDetector.LLRThresholds(threeLetters: 3, fourLetters: 2, longer: 1)
        XCTAssertEqual(t.threshold(forLength: 3), 3)
        XCTAssertEqual(t.threshold(forLength: 4), 2)
        XCTAssertEqual(t.threshold(forLength: 5), 1)
        XCTAssertEqual(t.threshold(forLength: 12), 1)

        let chosen = LanguageDetector.llrThresholds
        XCTAssertGreaterThanOrEqual(chosen.threeLetters, chosen.fourLetters)
        XCTAssertGreaterThanOrEqual(chosen.fourLetters, chosen.longer)
    }
```

Replace `testScores` with:

```swift
    // Scores are mean natural-log bigram probabilities now: negative,
    // closer to zero is more plausible. Only the ordering is meaningful.
    func testScores() {
        XCTAssertGreaterThan(LanguageDetector.russianScore("привет"), LanguageDetector.russianScore("руддщ") + 1)
        XCTAssertGreaterThan(LanguageDetector.englishScore("hello"), LanguageDetector.englishScore("ghbdtn") + 1)
    }
```

In `testDomainNameOverridesScoreHeuristic` delete the line
`XCTAssertGreaterThan(LanguageDetector.russianScore("нщгегиусщь"), LanguageDetector.russianThreshold)`
(Step 7 decides what replaces it).

Run: `swift test --filter LanguageDetectorTests`
Expected: FAIL to compile — нет `wrongLayoutLLR`, `llrThresholds`, `LLRThresholds`, параметра `thresholds:`.

- [ ] **Step 4: Replace the scoring in `LanguageDetector`**

In `Sources/LatCyr/LanguageDetector.swift`:

(a) Удалить целиком секции `// MARK: - Letter sets` и `// MARK: - Letter frequencies (normalized to 0...1)`.

(b) Секцию `// MARK: - Thresholds` заменить на:

```swift
    // MARK: - Thresholds

    /// Minimum log-likelihood ratio (see `wrongLayoutLLR`) at which a word
    /// is read as typed in the wrong layout, by the length of the word as
    /// typed. A three-letter word gives the model only four transitions to
    /// judge, so its LLR is noisy and needs the widest margin.
    public struct LLRThresholds: Equatable {
        public var threeLetters: Double
        public var fourLetters: Double
        public var longer: Double

        public init(threeLetters: Double, fourLetters: Double, longer: Double) {
            self.threeLetters = threeLetters
            self.fourLetters = fourLetters
            self.longer = longer
        }

        public static func uniform(_ value: Double) -> LLRThresholds {
            LLRThresholds(threeLetters: value, fourLetters: value, longer: value)
        }

        public func threshold(forLength length: Int) -> Double {
            length <= 3 ? threeLetters : length == 4 ? fourLetters : longer
        }
    }

    /// Chosen on a grid by scripts/eval-detector — the rule, the grid and
    /// the numbers are in docs/superpowers/specs/2026-10-13-bigram-scoring-design.md,
    /// §6–§7. Do not tune them to rescue individual words: every step
    /// trades caught words against false positives across tens of thousands
    /// of real ones. Individual words belong in the exception list.
    public static let llrThresholds = LLRThresholds(threeLetters: 2.0, fourLetters: 1.5, longer: 0.75)
    public static let minWordLength = 3
```

(Значения `2.0 / 1.5 / 0.75` — стартовые, Step 6 выбирает итоговые.)

(c) Секцию `// MARK: - Scoring` (функции `russianScore`, `englishScore` и приватную `score(...)`) заменить на:

```swift
    // MARK: - Scoring

    /// How Russian-looking a Cyrillic word is: the mean natural-log
    /// probability of its letter pairs, word boundaries included, under the
    /// Russian bigram model. Always negative; closer to zero is more Russian.
    public static func russianScore(_ word: String) -> Double {
        BigramModel.russian.averageLogProb(word)
    }

    /// How English-looking a Latin word is, on the same scale as `russianScore`.
    public static func englishScore(_ word: String) -> Double {
        BigramModel.english.averageLogProb(word)
    }
```

(d) Удалить функцию `strippingPunctuation(_:_:)` вместе с её doc-комментарием.

(e) Функцию `isWrongLayout` (вместе с её doc-комментарием) заменить на:

```swift
    /// Decide whether `word` (typed in the current layout) was meant to be
    /// typed in the other layout. `exceptions` overrides the score
    /// unconditionally: a word that is itself an exception is never flagged;
    /// a word whose conversion is an exception is always flagged —
    /// regardless of `thresholds`. So does a conversion that reads as a
    /// domain name (`looksLikeDomain`).
    ///
    /// `thresholds` defaults to `llrThresholds`; scripts/eval-detector passes
    /// others to sweep its grid.
    public static func isWrongLayout(
        word: String, currentLayoutIsRussian: Bool, exceptions: Set<String>,
        variant: TextConverter.RussianKeyboardVariant,
        thresholds: LLRThresholds = LanguageDetector.llrThresholds
    ) -> Bool {
        let lower = word.lowercased()
        guard isScorable(lower, variant: variant) else { return false }

        if exceptions.contains(lower) { return false }

        let converted = convert(lower, currentLayoutIsRussian: currentLayoutIsRussian, variant: variant)
        if exceptions.contains(converted) { return true }
        if looksLikeDomain(converted) { return true }

        return layoutLLR(original: lower, converted: converted, currentLayoutIsRussian: currentLayoutIsRussian)
            > thresholds.threshold(forLength: lower.count)
    }

    /// The score half of `isWrongLayout` on its own: how much more plausible
    /// the conversion is in the target language than the word as typed is in
    /// the current one, in mean natural-log probability per letter pair.
    /// Positive means the conversion reads better. `nil` when the word fails
    /// the length or character guards; exceptions and domains are not
    /// consulted.
    public static func wrongLayoutLLR(
        word: String, currentLayoutIsRussian: Bool,
        variant: TextConverter.RussianKeyboardVariant
    ) -> Double? {
        let lower = word.lowercased()
        guard isScorable(lower, variant: variant) else { return nil }
        let converted = convert(lower, currentLayoutIsRussian: currentLayoutIsRussian, variant: variant)
        return layoutLLR(original: lower, converted: converted, currentLayoutIsRussian: currentLayoutIsRussian)
    }

    private static func isScorable(_ lower: String, variant: TextConverter.RussianKeyboardVariant) -> Bool {
        lower.count >= minWordLength
            && lower.allSatisfy({ $0.isLetter || TextConverter.ambiguousLetterSymbols(for: variant).contains($0) })
    }

    private static func convert(
        _ lower: String, currentLayoutIsRussian: Bool,
        variant: TextConverter.RussianKeyboardVariant
    ) -> String {
        currentLayoutIsRussian
            ? TextConverter.toLatin(lower, variant: variant)
            : TextConverter.toCyrillic(lower, variant: variant)
    }

    /// One formula for both directions: target-language plausibility of the
    /// conversion minus current-language plausibility of the original.
    ///
    /// Neither side is filtered. Punctuation the conversion produces — a
    /// domain's dot, typed as "ю" — is outside the target model's alphabet,
    /// and BigramModel skips such characters on its own. The original is
    /// scored whole: б, ю, ж, х, э, ъ and ё sit on punctuation keys, but in
    /// the word as typed they are letters. Cutting them out, as the old
    /// letter-frequency score could afford to, left fragments no Russian
    /// word is made of — "был" scored as "ыл", "ещё" as "ещ" — and flagged
    /// the most frequent words of the language.
    private static func layoutLLR(original: String, converted: String, currentLayoutIsRussian: Bool) -> Double {
        currentLayoutIsRussian
            ? englishScore(converted) - russianScore(original)
            : russianScore(converted) - englishScore(original)
    }
```

`looksLikeDomain`, проактивные сигналы и весь блок `// MARK: - Carrying short function words` не трогать (их doc-комментарии правятся в Step 8).

Run: `swift build`
Expected: Build complete. Если компилятор находит `runPenalty`, `russianThreshold`, `englishThreshold`, `diffThreshold` или `strippingPunctuation` где-то ещё, удалить упоминания. По состоянию на этот коммит они встречаются только в `LanguageDetector.swift` и `LanguageDetectorTests.swift`.

- [ ] **Step 5: Build the tool against the new detector and draw the grid**

```bash
D="scripts/eval-data/man-tokens.txt scripts/eval-data/ru-dict.txt .build/eval/ru_holdout.txt .build/eval/en_holdout.txt Resources/exceptions.txt .build/frequencywords/ru_50k.txt .build/frequencywords/en_50k.txt"
swiftc -O -o .build/eval/eval-detector Sources/LatCyr/LanguageDetector.swift Sources/LatCyr/TextConverter.swift Sources/LatCyr/BigramModel.swift Sources/LatCyr/BigramTables.swift scripts/eval-detector/main.swift
.build/eval/eval-detector curve $D .build/eval/baseline-metrics.tsv > .build/eval/curve.tsv
wc -l .build/eval/curve.tsv
awk -F'\t' 'NR>1 && $17=="yes"' .build/eval/curve.tsv | sort -t$'\t' -k14,14g -k5,5gr | head -20
```

Expected: в `curve.tsv` около 120–160 строк, сетка считается несколько минут. Колонки: 1–3 — `t3 t4 t5`, 4 — `A`, 5 — `A'`, 6 — `B-caught`, 7 — `B-FP`, 8 — `C-caught`, 9 — `C-FP`, 10 — `D-FP`, 11 — `E`, 12 — `Y-FP`, 13 — `B-caught-w`, 14 — `B-FP-w`, 15 — `C-caught-w`, 16 — `C-FP-w`, 17 — `admissible`. Последняя команда печатает допустимые тройки в порядке выбора (спека, раздел 6, п. 5): меньше всего `B-FP-w`, при равенстве — больше `A'`. По прикидке контроллера допустимые тройки есть, например 2.0 / 1.5 / 0.75. Если допустимых нет совсем — остановиться и доложить (BLOCKED), приложив `.build/eval/curve.tsv`.

- [ ] **Step 6: Choose the thresholds and triage tests**

Взять первую строку отсортированного списка, записать её `t3 t4 t5` в `llrThresholds` (Step 4b) и запустить `swift test`.

Каждый упавший тест разобрать по таблице. Эти правила — часть задачи, а не рекомендация.

| Тест | Тип | Что делать при падении |
|---|---|---|
| `testFrequentEnglishWordsCaughtWithoutExceptions`, `testFrequentRussianWordsNotTouched`, `testRussianWordsWithRarePairsNotTouched` | новый, приёмка | Список не менять. Тройка не годится: взять следующую строку отсортированного списка Step 5 и повторить. Если строки кончились — BLOCKED. |
| `testShortEnglishTokensNotTouched` | новый, приёмка | Проверить слово базовой линией: `.build/eval/baseline words en <слово>`. Если базовая эвристика тоже его исправляла (`pc=true`), это не регрессия: убрать слово из списка и записать в 7.2 спеки как «ложное срабатывание и до, и после». Если базовая не исправляла — регрессия: взять следующую тройку. |
| `testRussianTypedInEnglishLayout`, `testWordWithAmbiguousPunctuationLetter`, `testEnglishTypedInRussianLayout`, `testCorrectWordsNotTouched`, `testShortWordsNotTouched`, `testWordsWithDigitsNotTouched`, `testDomainWithPunctuationDetected`, `testDomainsThatAlreadyWorkedStillDetected`, `testCorrectRussianWordsWhoseConversionHasPunctuationNotTouched`, `testPunctuationFilteringHoldsForBothVariants`, `testPunctuationInOriginalOnlyStillDetected`, `testDomainNameOverridesScoreHeuristic` (assert `isWrongLayout`), `testRussianWordsResemblingDomainsNotTouched`, все `proactive*`, все `Carriable*`/`Carry*`, `BundledExceptionsTests` | поведение пользователя | Тест **не менять**. Падение — регрессия: взять следующую тройку. Если строки кончились — BLOCKED. |
| `testExceptionWordNeverConverted` (`sdd` без исключений → `true`) | механизм исключений; слово — лишь предусловие | Найти замену: `.build/eval/eval-detector flagged en .build/eval/en_holdout.txt` — короткий настоящий английский токен, который сырая модель исправляет в `pc`. Заменить `sdd` в обеих строках теста, а комментарий переписать: «X typed correctly under the English layout is a false positive of the raw bigram score». |
| `testExceptionWordAlwaysCorrected` (`ыыд` без исключений → `false`) | механизм исключений | По прикидке контроллера `ыыд` теперь ловится без исключения (LLR 6.42). Подобрать латинскую запись из `Resources/exceptions.txt`, которую сырая модель **не** ловит в RU-раскладке: `.build/eval/eval-detector words ru <toCyrillic-форма>` (кандидаты — записи, у которых в строке `E` отчёта нет попадания; например `ыыр` (ssh), `гыи` (usb), `реез` (http), `цц` не годится — меньше 3 букв). Заменить в трёх строках теста (`toLatin`-проверка, `false` без исключений, `true` с исключением) и в комментарии. |
| `testCyrillicExceptionWordSymmetric` (`ффф` → `true` без исключений, `dep` → `false`) | механизм исключений | По прикидке `ффф` (LLR 1.69) не дотянет до трёхбуквенного порога. Подобрать кириллическое слово из одной повторённой буквы длиной ≥ 3, которое модель исправляет: `.build/eval/eval-detector words ru ффф фффф ффффф щщщ щщщщ ййй`. Заменить в тесте, сохранив смысл комментария. Для `dep` — латинское слово, которое модель не исправляет и чья конверсия — русское слово; `dep` → «вуз» по прикидке не исправляется (LLR −1.09). |
| `testRussianVariantGatesAmbiguousLetterGuard` (``h`c`` → `true` в `.pc`, `h\c` → `true` в `.apple`) | механизм гарда символов; слово — предусловие | По прикидке LLR ``h`c`` = 2.00, на грани трёхбуквенного порога. Если `true`-строки падают, подобрать слово длиной ≥ 4 с `` ` `` (`.pc`) / `\` (`.apple`) внутри, которое модель исправляет: `.build/eval/eval-detector words en '<слово>'` (в одинарных кавычках — обратная кавычка в двойных запускает подстановку команды); кандидаты (`.pc` / `.apple`): ``k`urbt`` / `k\urbt` (лёгкие), `` `krf `` / `\krf` (ёлка), ``gj`k`` / `gj\k` (пошёл). `false`-строки (другой вариант) от модели не зависят. Комментарий с числами 0.21 / 0.498 / 0.29 заменить на LLR из `words`. |

Повторять, пока `swift test` не станет зелёным. Итоговая тройка — первая строка отсортированного списка, на которой все тесты из строк «приёмка» и «поведение пользователя» проходят.

- [ ] **Step 7: Decide the domain-rule test**

```bash
.build/eval/eval-detector words ru нщгегиуюсщь нфтвучюкг пшергиюсщь фззудюсщь ьфшдюкг фмшещюкг рфикюсщь
```

(youtube.com, yandex.ru, github.com, apple.com, mail.ru, avito.ru, habr.com — все в `.pc`.)

- Если LLR у `нщгегиуюсщь` ≤ `LanguageDetector.llrThresholds.longer` (сама модель домен не ловит), вернуть в `testDomainNameOverridesScoreHeuristic` строку
  `XCTAssertLessThanOrEqual(LanguageDetector.wrongLayoutLLR(word: "нщгегиуюсщь", currentLayoutIsRussian: true, variant: .pc)!, LanguageDetector.llrThresholds.longer)`
  и заменить в комментарии «scores 0.468 — above russianThreshold» на фактический LLR.
- Иначе — если у какого-то другого кандидата из списка LLR ≤ порога для его длины, добавить в тест его тройку (`XCTAssertEqual(TextConverter.toLatin(...))`, `XCTAssertLessThanOrEqual(...wrongLayoutLLR..., LanguageDetector.llrThresholds.threshold(forLength: <длина>))`, `XCTAssertTrue(...isWrongLayout...)`) и переписать комментарий на этот пример.
- Иначе — оставить в тесте только `toLatin` и `isWrongLayout`, а комментарий переписать: модель теперь ловит такие домены сама (указать LLR `нщгегиуюсщь`), правило осталось безусловной страховкой, потому что домены всегда латиницей.

Run: `swift test --filter LanguageDetectorTests`
Expected: PASS.

- [ ] **Step 8: Update comments that describe the old mechanism**

В `Sources/LatCyr/LanguageDetector.swift`:
- `looksLikeDomain`: фразу «yet its filtered form scores 0.468 as Russian (over russianThreshold) because н, е, и, у and с are all high-frequency Russian letters» заменить по итогу Step 7: либо фактическим LLR и фразой «below its llrThresholds entry», либо фразой о том, что биграммная модель ловит домен сама, а правило остаётся безусловной страховкой (домены всегда латиницей), как исключения.
- `russianFunctionWords`: «lowering minWordLength or englishThreshold to admit such words» → «lowering minWordLength or llrThresholds to admit such words».

В `Tests/LatCyrTests/LanguageDetectorTests.swift` — комментарии (не код) тестов про пунктуацию, которые описывают фильтрацию:
- над `testDomainWithPunctuationDetected` — заменить на:
  ```swift
  // A word whose conversion contains punctuation — a domain name — must be
  // corrected whole, dot included. "фьфящтюву" is "amazon.de" typed under the
  // Russian layout. The English model skips the dot (it is not in its
  // alphabet); the Russian side is scored whole. Under the old
  // letter-frequency score the "ю" from the "." key held the word just over
  // the threshold, which is why scoring used to filter punctuation out.
  ```
- над `testDomainsThatAlreadyWorkedStillDetected` — фразу «filtering shortens the scored word, and a shorter word must not drift back over a threshold» заменить на «skipping the dot shortens the English side, and a shorter word must not drift below its threshold».
- над `testCorrectRussianWordsWhoseConversionHasPunctuationNotTouched` — «Filtering must not turn any of these into a false positive» → «Skipping the conversion's punctuation must not turn any of these into a false positive».
- над `testPunctuationFilteringHoldsForBothVariants` — «so both must be filtered out of scoring» → «and the English model skips both».
- над `testPunctuationInOriginalOnlyStillDetected` — заменить на:
  ```swift
  // Punctuation in the original is skipped by the English model, while the
  // conversion's letters are scored in full: under the English layout ","
  // and "]" are the "б" and "ъ" keys, so these words must behave exactly as
  // they did before.
  ```

Проверка:

```bash
grep -nE "russianThreshold|englishThreshold|diffThreshold|runPenalty|strippingPunctuation|llrThreshold([^s]|$)|0\.468|0\.424|0\.323|filtered out of scoring|Filtering" Sources/LatCyr/LanguageDetector.swift Tests/LatCyrTests/LanguageDetectorTests.swift
```

Expected: пустой вывод.

- [ ] **Step 9: Measure "after" and record it**

```bash
D="scripts/eval-data/man-tokens.txt scripts/eval-data/ru-dict.txt .build/eval/ru_holdout.txt .build/eval/en_holdout.txt Resources/exceptions.txt .build/frequencywords/ru_50k.txt .build/frequencywords/en_50k.txt"
swiftc -O -o .build/eval/eval-detector Sources/LatCyr/LanguageDetector.swift Sources/LatCyr/TextConverter.swift Sources/LatCyr/BigramModel.swift Sources/LatCyr/BigramTables.swift scripts/eval-detector/main.swift
.build/eval/eval-detector report $D | tee .build/eval/after-report.txt
```

В спеке раздел `### 7.2 После` (заглушку) заменить на:
- выбранные пороги `t3 / t4 / t5` и одну-две фразы, почему они: первая допустимая тройка по правилу п. 5 раздела 6, либо, если первые строки отпали в Step 6, какие тесты их отсеяли;
- полный `.build/eval/after-report.txt` в блоке кода;
- таблицу «до/после» по каждой из 13 метрик для `pc` (метрика, до %, после %), отметив варианты как совпадающие;
- первые 10 строк отсортированного списка допустимых троек из Step 5 (с заголовком колонок) и число допустимых троек из общего числа;
- строку `E` («из N латинских записей exceptions.txt без исключений ловится M») и фразу, что чистка списка — отдельное решение;
- 20 самых частых ложных срабатываний на русских словах после изменения — для сведения. Команды:
  `.build/eval/eval-detector flagged ru .build/eval/ru_holdout.txt | cut -f1 > .build/eval/fp-after.txt`, затем
  `awk 'NR==FNR{c[$1]+=$2; next} {print c[$1]+0, $1}' <(sed 's/ё/е/g' .build/frequencywords/ru_50k.txt) .build/eval/fp-after.txt | sort -rn | head -20`;
- список слов, убранных из тестов в Step 6 как «ложное срабатывание и до, и после», и слова-замены в тестах-предусловиях (`sdd`, `ыыд`, `ффф`, ``h`c``), если менялись;
- параметры генератора — без изменений.

Обновить статус в шапке спеки: `**Статус:** утверждён; пересмотрен 2026-10-14 (раздел 2.3); реализован, цифры в разделе 7`.

- [ ] **Step 10: Full verification and commit**

Run: `swift test`
Expected: PASS, 0 failures.

Run: `swift build`
Expected: Build complete.

```bash
git add Sources/LatCyr/LanguageDetector.swift Tests/LatCyrTests/LanguageDetectorTests.swift docs/superpowers/specs/2026-10-13-bigram-scoring-design.md
git commit -m "feat: decide wrong layout by bigram likelihood ratio

Replaces the single-letter frequency score, whose Russian half rated
gibberish like \"ашду\" (file) as Russian because every letter in it is
common. The original is scored whole and thresholds depend on word
length; the choice and before/after numbers are in the spec, section 7.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Документация в `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: итоговый порог и цифры из спеки, раздел 7 (Task 4); `.build/eval/eval-detector` для свежих чисел.
- Produces: актуальный `CLAUDE.md`.

- [ ] **Step 1: Commands section**

В блок `## Команды` после строки `./scripts/package-app.sh …` добавить:

```bash
# замер детектора (подробно — docs/superpowers/specs/2026-10-13-bigram-scoring-design.md, §5)
swiftc -O -o .build/eval/eval-detector Sources/LatCyr/LanguageDetector.swift Sources/LatCyr/TextConverter.swift Sources/LatCyr/BigramModel.swift Sources/LatCyr/BigramTables.swift scripts/eval-detector/main.swift
.build/eval/eval-detector words ru ашду     # решение и LLR для отдельных слов
```

- [ ] **Step 2: Architecture paragraph**

В абзаце «Ключевой принцип изоляции» перечень чистых функций `(TextConverter, LanguageDetector)` расширить до `(TextConverter, LanguageDetector, BigramModel)`.

- [ ] **Step 3: Replace the thresholds bullet**

Пункт, начинающийся с `- **Пороги эвристики**`, заменить на:

```markdown
- **Скоринг — отношение правдоподобий двух биграммных моделей (`BigramModel`):** `LanguageDetector.wrongLayoutLLR` = средний натуральный log вероятности пар букв конверсии (с маркерами начала и конца слова) по модели целевого языка минус то же для набранного слова по модели текущего; слово исправляется, если LLR больше порога для его длины (`llrThresholds`: 3 буквы — <t3>, 4 — <t4>, 5 и больше — <t5>; у короткого слова всего четыре перехода, и его LLR шумит). Одна формула на оба направления. Побуквенная частота, которая была раньше, не отличала «ашду» (file в русской раскладке) от русского слова — все буквы в ней частые; пары («аш» в начале, «ду» в конце) отличают. Таблицы (`Sources/LatCyr/BigramTables.swift`) сгенерированы `scripts/gen-bigrams.swift` из FrequencyWords (CC BY-SA 4.0, атрибуция в шапке файла), руками не правятся; пересборка таблиц меняет поведение детектора и требует нового замера. Пороги выбраны по сетке `scripts/eval-detector curve` по правилу из спеки (`docs/superpowers/specs/2026-10-13-bigram-scoring-design.md`, §6–§7) и **не подкручиваются ради отдельных слов** — каждый шаг меняет баланс пойманных и ложных на десятках тысяч слов; отдельные слова — через исключения. Замер обязан включать частотно-взвешенные строки: по уникальным словам «был» весит как редкое слово, а пользователь замечает именно частые. Слова короче `minWordLength` = 3 ретроактивно не исправляются. UI настроек порогов в v1 нет.
```

Угловые скобки — подстановка фактических значений из `llrThresholds`.

- [ ] **Step 4: Fix bullets that quote old scores**

Каждое число получить командой `.build/eval/eval-detector words <ru|en> <слово>` и вписать как LLR:

- Пункт `- **Доменное имя в конверсии — безусловный сигнал (looksLikeDomain)…`: фразу про `russianScore` = 0.468 при пороге 0.4 и «Понижать порог нельзя…» переписать согласно итогу Task 4 Step 7 (тот же вывод, что в doc-комментарии `looksLikeDomain`).
- Пункт `- **Скоринг игнорирует позиции, где конверсия даёт пунктуацию:**` заменить целиком на:

  ```markdown
  - **Пунктуация в конверсии пропускается моделью, оригинал оценивается целиком:** `BigramModel.averageLogProb` пропускает символы вне своего алфавита, поэтому точка домена (`amazon.de`, набранное как «фьфящтюву») в английскую оценку не попадает — отдельной фильтрации нет. Оригинал не фильтруется: б, ю, ж, х, э, ъ, ё стоят на пунктуационных клавишах, но в набранном слове это буквы. Прежняя `strippingPunctuation` вырезала их позиции из обеих строк — побуквенной эвристике это не мешало, а биграммная оценивала «был» как «ыл» и «ещё» как «ещ» и исправляла самые частые слова языка (спека биграммного скоринга, §2.3). Разбивать такое слово по пунктуации на границе по-прежнему нельзя: «фьфящт» + «ву» дало бы `amazon` + неисправленное «ву». `minWordLength`, проверка «только буквы и неоднозначные символы» и оба сравнения с `exceptions` работают с полным словом; заменяется в тексте тоже полное слово.
  ```
- Пункт `- **Подхват коротких служебных слов (CarryBuffer)…`: фразу «`yfl` → «над» даёт `englishScore` 0.439 при пороге 0.35, потому что `y` — английская гласная…» заменить на фактическое поведение: `.build/eval/eval-detector words en yfl`. Если `yfl` теперь ловится сам по себе, оставить общий тезис (1–2-буквенные слова не оценить, а трёхбуквенные — не всегда) и пример убрать. «Понижать пороги нельзя» → «Понижать `minWordLength` или `llrThresholds` нельзя».

Проверка:

```bash
grep -nE "russianThreshold|englishThreshold|diffThreshold|runPenalty|strippingPunctuation|llrThreshold([^s]|$)|0\.468|0\.424|0\.323|0\.439|сигнальные буквы" CLAUDE.md
```

Expected: пустой вывод.

- [ ] **Step 5: Tests section**

В разделе `## Тесты`:

- В перечень после `TextConverterTests` добавить: «`BigramModelTests` (усреднение по переходам с маркерами начала и конца, «ё»→«е», пропуск символов вне алфавита, пол вероятности; sanity реальных таблиц — «привет» правдоподобнее «ашду», «hello» правдоподобнее «ghbdtn»)».
- В описание `LanguageDetectorTests` добавить: «частые английские слова в русской раскладке ловятся без исключений («ашду», «ершы», «ащк»…), русские слова с редкими парами, самые частые русские слова («был», «ещё», «тут»…) и короткие команды (`npm`, `ssh`, `grep`…) не трогаются, `wrongLayoutLLR`, явные пороги и выбор порога по длине».
- Фразу про бандловый список «(русская оценка их записи ≥ 0.4: «ашду» для `file`, «ершы» для `this`)» заменить на «(слова, которые пропускала прежняя побуквенная эвристика; сколько из них биграммная модель ловит сама — в спеке биграммного скоринга, §7)».
- В конец раздела добавить абзац: «Качество детектора измеряется не юнит-тестами, а `scripts/eval-detector` (наборы: токены man-страниц, проверочные половины FrequencyWords — по словам и по частоте употребления, русский словарь из NSSpellChecker, слова с «ё»; данные — в `scripts/eval-data/`, проверочные половины пересоздаёт `scripts/gen-bigrams.swift` в `.build/eval/`). Любое изменение скоринга или таблиц сопровождается прогоном `report` до и после, а порогов — `curve`.»

- [ ] **Step 6: Verify and commit**

Run: `swift test`
Expected: PASS.

```bash
git add CLAUDE.md
git commit -m "docs: describe bigram scoring, its tables and the evaluation tool

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
