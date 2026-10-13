# Биграммный скоринг раскладки — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Заменить побуквенный частотный скоринг в `LanguageDetector.isWrongLayout` на отношение правдоподобий (LLR) двух биграммных моделей — русской и английской — и подтвердить улучшение воспроизводимым замером.

**Architecture:** Новый чистый тип `BigramModel` (таблица log-вероятностей пар букв с маркерами начала и конца слова). Таблицы генерируются одноразовым скриптом из FrequencyWords и встраиваются в Swift-файл. `isWrongLayout` сохраняет все проверки до скоринга (длина, символы, исключения, домен, фильтрация пунктуации), а три старых порога заменяет одним `llrThreshold`. Отдельный инструмент замера `scripts/eval-detector/main.swift` даёт базовую линию до изменения и цифры после.

**Tech Stack:** Swift 5.9 Package (без Xcode), XCTest, `swiftc` для скриптов, AppKit `NSSpellChecker` только в инструменте замера.

**Spec:** `docs/superpowers/specs/2026-10-13-bigram-scoring-design.md`.

## Global Constraints

- Во время работы приложения ни сети, ни чтения файлов для скоринга: таблицы — Swift-литералы в `Sources/LatCyr/BigramTables.swift`.
- Источник данных: FrequencyWords, коммит `525f9b560de45753a5ea01069454e72e9aa541c6`, файлы `content/2018/ru/ru_50k.txt` (sha256 `6095f507cc167488ec66ada5a85ac50433503a08ad24a07c6eabdf54352c4e7f`) и `content/2018/en/en_50k.txt` (sha256 `5351ff405b1126ef555791dd4d9798a48e3e9a501a9fc481a9da957752cfb458`). Лицензия данных CC BY-SA 4.0 (© Hermit Dave), код — MIT. Сами списки не коммитятся.
- Параметры генератора: слова длиной ≥ 3, «ё»→«е», только буквы алфавита, вес `log(1 + count)`, совместная вероятность по всем переходам, пол `1e-7`, натуральный логарифм; в обучение идут только слова с чётным FNV-1a хешем (64-бит, по UTF-8 байтам нормализованного слова), нечётные — проверочная половина.
- Нельзя «просто понизить порог» ради отдельных слов. Порог выбирается по правилу из Task 4, исключения (`Resources/exceptions.txt`) в этой работе не меняются.
- Поведение, которое не должно меняться: `minWordLength` = 3, проактивные сигналы, `looksLikeDomain`/`knownTLDs`, `strippingPunctuation`, `isCarriableFunctionWord`.
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

### Task 4: LLR-решение в `LanguageDetector`

**Files:**
- Modify: `Sources/LatCyr/LanguageDetector.swift`
- Modify: `Tests/LatCyrTests/LanguageDetectorTests.swift`
- Modify: `scripts/eval-detector/main.swift` (режим `curve`, LLR в `words`)
- Modify: `docs/superpowers/specs/2026-10-13-bigram-scoring-design.md` (раздел 7.2)

**Interfaces:**
- Consumes: `BigramModel.russian`, `BigramModel.english`, `averageLogProb` (Tasks 1–2); `report(paths:decide:)`, `ReportPaths`, `Decide`, `.build/eval/baseline` (Task 3).
- Produces:
  - `public static let llrThreshold: Double`
  - `public static func isWrongLayout(word: String, currentLayoutIsRussian: Bool, exceptions: Set<String>, variant: TextConverter.RussianKeyboardVariant, threshold: Double = LanguageDetector.llrThreshold) -> Bool` — существующие вызовы (`InputMonitor`, `CarryBuffer`-логика, тесты) компилируются без изменений.
  - `public static func wrongLayoutLLR(word: String, currentLayoutIsRussian: Bool, variant: TextConverter.RussianKeyboardVariant) -> Double?` — `nil`, если слово не прошло проверки длины и символов; исключения и домен не учитывает.
  - `russianScore(_:)` / `englishScore(_:)` — те же сигнатуры, новая шкала (средний натуральный log, отрицательный).
  - Удалены: `russianThreshold`, `englishThreshold`, `diffThreshold`.

- [ ] **Step 1: Write the new failing tests**

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

    // Correct Russian words built from rare pairs (щ, ъ, ы, э, "ещё" whose
    // "ё" key converts to punctuation and is filtered out of scoring). These
    // are where a bigram model is most likely to misfire.
    func testRussianWordsWithRarePairsNotTouched() {
        for word in ["ещё", "шею", "щука", "съезд", "объект", "этот", "мысль", "вообще", "подъезд",
                     "взгляд", "чувство", "следующий", "объявление", "здравствуйте"] {
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
        XCTAssertGreaterThan(wrong, LanguageDetector.llrThreshold)
        XCTAssertLessThan(right, LanguageDetector.llrThreshold)
    }

    // An explicit threshold overrides the default — the evaluation tool
    // sweeps it to draw the threshold curve.
    func testExplicitThreshold() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ghbdtn", currentLayoutIsRussian: false, exceptions: [], variant: .pc, threshold: -100))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "ghbdtn", currentLayoutIsRussian: false, exceptions: [], variant: .pc, threshold: 100))
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
Expected: FAIL to compile — `wrongLayoutLLR`, `llrThreshold` и параметр `threshold:` не существуют.

- [ ] **Step 2: Replace the scoring in `LanguageDetector`**

In `Sources/LatCyr/LanguageDetector.swift`:

(a) Удалить целиком секции `// MARK: - Letter sets` и `// MARK: - Letter frequencies (normalized to 0...1)` (множества `russianVowels`, `russianConsonants`, `englishVowels`, `englishConsonants`, словари `russianFreq`, `englishFreq`).

(b) Секцию `// MARK: - Thresholds` заменить на:

```swift
    // MARK: - Thresholds

    /// Minimum log-likelihood ratio (see `wrongLayoutLLR`) at which a word is
    /// read as typed in the wrong layout. Chosen by measurement with
    /// scripts/eval-detector — the curve and the reasoning are in
    /// docs/superpowers/specs/2026-10-13-bigram-scoring-design.md, §7. Do not
    /// tune it to rescue individual words: every step trades caught words
    /// against false positives across tens of thousands of real ones.
    public static let llrThreshold = 1.0
    public static let minWordLength = 3
```

(Значение `1.0` — стартовое, Step 5 выбирает итоговое.)

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

(d) Функцию `isWrongLayout` (вместе с её doc-комментарием) заменить на:

```swift
    /// Decide whether `word` (typed in the current layout) was meant to be
    /// typed in the other layout. `exceptions` overrides the score
    /// unconditionally: a word that is itself an exception is never flagged;
    /// a word whose conversion is an exception is always flagged —
    /// regardless of `threshold`. So does a conversion that reads as a
    /// domain name (`looksLikeDomain`).
    ///
    /// `threshold` defaults to `llrThreshold`; scripts/eval-detector passes
    /// other values to draw the threshold curve.
    public static func isWrongLayout(
        word: String, currentLayoutIsRussian: Bool, exceptions: Set<String>,
        variant: TextConverter.RussianKeyboardVariant,
        threshold: Double = LanguageDetector.llrThreshold
    ) -> Bool {
        let lower = word.lowercased()
        guard isScorable(lower, variant: variant) else { return false }

        if exceptions.contains(lower) { return false }

        let converted = convert(lower, currentLayoutIsRussian: currentLayoutIsRussian, variant: variant)
        if exceptions.contains(converted) { return true }
        if looksLikeDomain(converted) { return true }

        return layoutLLR(original: lower, converted: converted, currentLayoutIsRussian: currentLayoutIsRussian) > threshold
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
    /// conversion minus current-language plausibility of the original, both
    /// scored on the punctuation-filtered pair.
    private static func layoutLLR(original: String, converted: String, currentLayoutIsRussian: Bool) -> Double {
        let scored = strippingPunctuation(original, converted)
        return currentLayoutIsRussian
            ? englishScore(scored.converted) - russianScore(scored.original)
            : russianScore(scored.converted) - englishScore(scored.original)
    }
```

`looksLikeDomain`, `strippingPunctuation`, проактивные сигналы и весь блок `// MARK: - Carrying short function words` не трогать (их doc-комментарии правятся в Step 8).

Run: `swift build`
Expected: Build complete. Если компилятор ругается на `runPenalty`, `russianThreshold`, `englishThreshold` или `diffThreshold` где-то ещё, удалить эти упоминания: по состоянию на `8a414f7` они используются только в `LanguageDetector.swift` и в тесте из Step 1.

- [ ] **Step 3: Extend the eval tool**

In `scripts/eval-detector/main.swift`:

(a) В шапку, в список режимов, добавить строку:

```swift
//   curve <same five paths as report>   report at llrThreshold 0.5 ... 2.0, step 0.25
```

(b) Функцию `words(russianActive:_:)` заменить на:

```swift
func words(russianActive: Bool, _ list: [String]) {
    for word in list {
        let decisions = variants.map { v -> String in
            let llr = LanguageDetector.wrongLayoutLLR(word: word, currentLayoutIsRussian: russianActive, variant: v)
                .map { String(format: "%.2f", $0) } ?? "n/a"
            return "\(v)=\(detector(word, russianActive, v)) llr=\(llr)"
        }
        print("\(word)\t\(decisions.joined(separator: "  "))")
    }
}
```

(c) В `switch` перед `default:` добавить:

```swift
case "curve" where args.count == 7:
    let paths = ReportPaths(manTokens: args[2], ruDict: args[3], ruHoldout: args[4], enHoldout: args[5], exceptions: args[6])
    for threshold in stride(from: 0.5, through: 2.0, by: 0.25) {
        print("=== llrThreshold \(threshold)")
        report(paths: paths, decide: { typed, russianActive, variant in
            LanguageDetector.isWrongLayout(word: typed, currentLayoutIsRussian: russianActive, exceptions: [], variant: variant, threshold: threshold)
        })
    }
```

Build:

```bash
swiftc -O -o .build/eval/eval-detector Sources/LatCyr/LanguageDetector.swift Sources/LatCyr/TextConverter.swift Sources/LatCyr/BigramModel.swift Sources/LatCyr/BigramTables.swift scripts/eval-detector/main.swift
```

Expected: собирается без ошибок. **Не перезаписывать** `.build/eval/baseline`.

- [ ] **Step 4: Draw the curve**

```bash
.build/eval/eval-detector curve scripts/eval-data/man-tokens.txt scripts/eval-data/ru-dict.txt .build/eval/ru_holdout.txt .build/eval/en_holdout.txt Resources/exceptions.txt | tee .build/eval/curve.txt
```

Expected: 7 блоков по 16 строк.

- [ ] **Step 5: Choose the threshold**

Правило (критерии — спека, раздел 6). Порог `t` из кривой **допустим**, если для обоих вариантов (`pc`, `apple`) одновременно:

1. каждая строка `FALSE POSITIVE` (`B … typed correctly`, `C … typed correctly`, `D …`) — не выше соответствующей строки `.build/eval/baseline-report.txt`;
2. доля **пропущенных** в `A'` и в `C … typed in RU layout` (100% − caught%) — не больше половины базовой;
3. `B … typed in EN layout: caught` — не ниже базовой.

Из допустимых взять порог с максимальным `A' caught`; при равенстве — больший порог (меньше ложных). Если нужно, уточнить шагом 0.05 вокруг выбранного значения, временно поменяв `stride` в `curve` (изменение `stride` не коммитить).

Если **ни один** одиночный порог не допустим, но допустима пара (один порог для RU-активной раскладки — строки A, A', B-FP, C-caught, D, E; другой — для EN-активной: B-caught, C-FP), ввести два порога. Для этого `llrThreshold` заменить на:

```swift
    public static let llrThresholdRussianActive = <выбранное значение>
    public static let llrThresholdEnglishActive = <выбранное значение>
    public static func llrThreshold(currentLayoutIsRussian: Bool) -> Double {
        currentLayoutIsRussian ? llrThresholdRussianActive : llrThresholdEnglishActive
    }
```

Параметр `isWrongLayout` в этом случае становится `threshold: Double? = nil` и используется как `threshold ?? llrThreshold(currentLayoutIsRussian: currentLayoutIsRussian)`. `testWrongLayoutLLR` сравнивает с `llrThreshold(currentLayoutIsRussian: false)`, `curve` прогоняет общую сетку, и пара выбирается по соответствующим строкам.

Если не допустима и пара — **остановиться и доложить** (статус BLOCKED) с файлом `.build/eval/curve.txt`. Не подбирать параметры генератора и не трогать исключения без согласования.

Записать выбранное значение в `llrThreshold` (Step 2b), пересобрать инструмент (команда из Step 3).

- [ ] **Step 6: Run the tests and triage failures**

Run: `swift test`

Каждый упавший тест разобрать по таблице. Эти правила — часть задачи, а не рекомендация.

| Тест | Тип | Что делать при падении |
|---|---|---|
| `testFrequentEnglishWordsCaughtWithoutExceptions` | новый, приёмка | Не менять список. Значит, порог не годится: вернуться к Step 5, исключив пороги, где тест падает. Если таких не остаётся — BLOCKED. |
| `testRussianWordsWithRarePairsNotTouched`, `testShortEnglishTokensNotTouched` | новый, приёмка | Проверить слово базовой линией: `.build/eval/baseline words ru <слово>` (или `en`). Если базовая эвристика тоже его исправляла (`true`), это не регрессия: убрать слово из списка и записать в 7.2 спеки как «ложное срабатывание и до, и после». Если базовая не исправляла — регрессия: вернуться к Step 5 и исключить этот порог. Если таких порогов не остаётся — BLOCKED. |
| `testRussianTypedInEnglishLayout`, `testWordWithAmbiguousPunctuationLetter`, `testEnglishTypedInRussianLayout`, `testCorrectWordsNotTouched`, `testShortWordsNotTouched`, `testWordsWithDigitsNotTouched`, `testDomainWithPunctuationDetected`, `testDomainsThatAlreadyWorkedStillDetected`, `testCorrectRussianWordsWhoseConversionHasPunctuationNotTouched`, `testPunctuationFilteringHoldsForBothVariants`, `testPunctuationInOriginalOnlyStillDetected`, `testDomainNameOverridesScoreHeuristic` (assert `isWrongLayout`), `testRussianWordsResemblingDomainsNotTouched`, все `proactive*`, все `Carriable*`/`Carry*`, `BundledExceptionsTests` | поведение пользователя | Тест **не менять**. Падение — регрессия: как в строке выше (вернуться к Step 5; если порогов не остаётся — BLOCKED). |
| `testExceptionWordNeverConverted` (`sdd` без исключений → `true`) | механизм исключений; слово — лишь предусловие | Если `sdd` больше не исправляется сырой моделью, найти замену: `.build/eval/eval-detector flagged en .build/eval/en_holdout.txt`, взять из вывода короткий настоящий английский токен (проверить словарём или здравым смыслом), исправляемый в `pc`, заменить `sdd` в обеих строках теста, а комментарий переписать: «X typed correctly under the English layout is a false positive of the raw bigram score». |
| `testExceptionWordAlwaysCorrected` (`ыыд` без исключений → `false`) | механизм исключений | Если `ыыд` теперь ловится и без исключения, подобрать другую латинскую аббревиатуру из `Resources/exceptions.txt`, которую сырая модель не ловит: `.build/eval/eval-detector words ru <toCyrillic-форма>`, например `ыыр` (ssh), `гыи` (usb), `реез` (http). Заменить в трёх строках теста и в комментарии. |
| `testCyrillicExceptionWordSymmetric` (`ффф` → `true`, `dep` → `false` без исключений) | механизм исключений | Если предусловие нарушено, подобрать аналог с тем же свойством через `eval-detector words` (для `ффф` — кириллица из одной повторённой буквы, которую модель исправляет; для `dep` — латинское слово, которое модель не исправляет и чья конверсия — русское слово). Заменить в тесте, сохранив смысл комментария. |
| `testRussianVariantGatesAmbiguousLetterGuard` (``h`c`` → `true` в `.pc`, `h\c` → `true` в `.apple`) | механизм гарда символов; слово — предусловие | Если `true`-строки падают, подобрать другое слово с `` ` `` (`.pc`) / `\` (`.apple`) внутри, которое модель исправляет: `.build/eval/eval-detector words en '<слово>'`, кандидаты (`.pc` / `.apple`): ``k`urbt`` / `k\urbt` (лёгкие), `` `krf `` / `\krf` (ёлка); в shell передавать в одинарных кавычках (обратная кавычка внутри двойных запускает подстановку команды). `false`-строки (другой вариант) от модели не зависят. Комментарий с числами 0.21 / 0.498 / 0.29 заменить на LLR из `words`. |

Повторять Step 5–6, пока `swift test` не станет зелёным.

- [ ] **Step 7: Decide the domain-rule test**

```bash
.build/eval/eval-detector words ru нщгегиуюсщь нфтвучюкг пшергиюсщь фззудюсщь ьфшдюкг фмшещюкг рфикюсщь
```

(youtube.com, yandex.ru, github.com, apple.com, mail.ru, avito.ru, habr.com, все в `.pc`.)

- Если LLR у `нщгегиуюсщь` ≤ порога (сама модель домен не ловит), вернуть в `testDomainNameOverridesScoreHeuristic` строку
  `XCTAssertLessThanOrEqual(LanguageDetector.wrongLayoutLLR(word: "нщгегиуюсщь", currentLayoutIsRussian: true, variant: .pc)!, LanguageDetector.llrThreshold)`
  и заменить в комментарии «scores 0.468 — above russianThreshold» на фактический LLR.
- Иначе — если какой-то другой кандидат из списка имеет LLR ≤ порога, добавить в тест его пару (`XCTAssertEqual(TextConverter.toLatin(...))`, `XCTAssertLessThanOrEqual(...wrongLayoutLLR...)`, `XCTAssertTrue(...isWrongLayout...)`) и переписать комментарий на этот пример.
- Иначе — оставить в тесте только `toLatin` и `isWrongLayout`, а комментарий переписать так: модель теперь ловит такие домены сама (указать LLR `нщгегиуюсщь`), правило осталось безусловной страховкой, потому что домены всегда латиницей.

Run: `swift test --filter LanguageDetectorTests`
Expected: PASS.

- [ ] **Step 8: Update doc comments with stale numbers**

В `Sources/LatCyr/LanguageDetector.swift`:

- `looksLikeDomain`: фразу «yet its filtered form scores 0.468 as Russian (over russianThreshold) because н, е, и, у and с are all high-frequency Russian letters» заменить по итогу Step 7. Либо фактическим LLR и фразой «below llrThreshold», либо фразой о том, что биграммная модель ловит домен сама, а правило остаётся безусловной страховкой (домены всегда латиницей), как исключения.
- `strippingPunctuation`: «enough to hold a genuine wrong-layout word above russianThreshold» → «enough to shift a genuine wrong-layout word's LLR». Затем проверить и вписать фактическое число: `.build/eval/eval-detector words ru фьфящтюву` (с фильтрацией). Если LLR без фильтрации посчитать нечем, оставить фразу без числа.
- `russianFunctionWords`: «lowering minWordLength or englishThreshold to admit such words» → «lowering minWordLength or llrThreshold to admit such words».

Проверка, что старых имён не осталось:

```bash
grep -n "russianThreshold\|englishThreshold\|diffThreshold\|runPenalty\|0\.468\|0\.424\|0\.323" Sources Tests -r
```

Expected: пустой вывод.

- [ ] **Step 9: Measure "after" and record it**

```bash
.build/eval/eval-detector report scripts/eval-data/man-tokens.txt scripts/eval-data/ru-dict.txt .build/eval/ru_holdout.txt .build/eval/en_holdout.txt Resources/exceptions.txt | tee .build/eval/after-report.txt
paste .build/eval/baseline-report.txt .build/eval/after-report.txt | head -2
```

В спеке раздел `### 7.2 После` (заглушку из Task 3) заменить на:

- выбранный порог (или пару) и одну-две фразы, почему он (какое правило Step 5 его определило);
- полный `.build/eval/after-report.txt` в блоке кода;
- таблицу «до/после» по каждой строке отчёта для `pc` и `apple` (метрика, до %, после %);
- блок строк кривой (`.build/eval/curve.txt`) для порогов, соседних с выбранным;
- строку `E` («из N латинских записей exceptions.txt без исключений ловится M») и фразу, что чистка списка — отдельное решение;
- список слов, убранных из тестов в Step 6 как «ложное срабатывание и до, и после», если такие были;
- параметры генератора (из Global Constraints) и пометку, что они не менялись (или что именно изменили и почему, если в Step 5 выяснилось иное — но такие изменения требуют согласования, см. BLOCKED).

Также обновить статус в шапке спеки: `**Статус:** утверждён; реализован, цифры в разделе 7`.

- [ ] **Step 10: Full verification and commit**

Run: `swift test`
Expected: PASS, 0 failures.

Run: `swift build`
Expected: Build complete.

```bash
git add Sources/LatCyr/LanguageDetector.swift Tests/LatCyrTests/LanguageDetectorTests.swift scripts/eval-detector/main.swift docs/superpowers/specs/2026-10-13-bigram-scoring-design.md
git commit -m "feat: decide wrong layout by bigram likelihood ratio

Replaces the single-letter frequency score, whose Russian half rated
gibberish like \"ашду\" (file) as Russian because every letter in it is
common. Threshold and before/after numbers are in the spec, section 7.

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
- **Скоринг — отношение правдоподобий двух биграммных моделей (`BigramModel`):** `LanguageDetector.wrongLayoutLLR` = средний натуральный log вероятности пар букв конверсии (с маркерами начала и конца слова) по модели целевого языка минус то же для набранного слова по модели текущего; слово исправляется, если LLR > `llrThreshold` (<выбранное значение из спеки, §7>). Одна формула на оба направления. Побуквенная частота, которая была раньше, не отличала «ашду» (file в русской раскладке) от русского слова — все буквы в ней частые; пары («аш» в начале, «ду» в конце) отличают. Таблицы (`Sources/LatCyr/BigramTables.swift`) сгенерированы `scripts/gen-bigrams.swift` из FrequencyWords (CC BY-SA 4.0, атрибуция в шапке файла), руками не правятся; пересборка таблиц меняет поведение детектора и требует нового замера. Порог выбран замером `scripts/eval-detector` по правилу из спеки (`docs/superpowers/specs/2026-10-13-bigram-scoring-design.md`, §7) и **не подкручивается ради отдельных слов** — каждый шаг меняет баланс пойманных и ложных на десятках тысяч слов; отдельные слова — через исключения. Слова короче `minWordLength` = 3 ретроактивно не исправляются. UI настроек порогов в v1 нет.
```

Угловые скобки — подстановка фактического значения (или пары значений с пояснением, если в Task 4 выбраны два порога).

- [ ] **Step 4: Fix bullets that quote old scores**

Каждое число получить командой `.build/eval/eval-detector words <ru|en> <слово>` и вписать как LLR:

- Пункт `- **Доменное имя в конверсии — безусловный сигнал (looksLikeDomain)…`: фразу про `russianScore` = 0.468 при пороге 0.4 и «Понижать порог нельзя…» переписать согласно итогу Task 4 Step 7 (тот же вывод, что в doc-комментарии `looksLikeDomain`).
- Пункт `- **Скоринг игнорирует позиции, где конверсия даёт пунктуацию:**`: числа 0.424 / 0.323 / 0.4 заменить на LLR `фьфящтюву` с фильтрацией и формулировкой «выше/ниже `llrThreshold`». Если LLR без фильтрации посчитать нечем, убрать числа и оставить механизм: точка, прочитанная как «ю», сдвигает оценку.
- Пункт `- **Подхват коротких служебных слов (CarryBuffer)…`: фразу «`yfl` → «над» даёт `englishScore` 0.439 при пороге 0.35, потому что `y` — английская гласная…» заменить на фактическое поведение: `.build/eval/eval-detector words en yfl`. Если `yfl` теперь ловится сам по себе, оставить общий тезис (1–2-буквенные слова не оценить, а трёхбуквенные — не всегда) и пример убрать. «Понижать пороги нельзя» → «Понижать `minWordLength` или `llrThreshold` нельзя».

Проверка:

```bash
grep -n "russianThreshold\|englishThreshold\|diffThreshold\|runPenalty\|0\.468\|0\.424\|0\.323\|0\.439\|сигнальные буквы" CLAUDE.md
```

Expected: пустой вывод.

- [ ] **Step 5: Tests section**

В разделе `## Тесты`:

- В перечень после `TextConverterTests` добавить: «`BigramModelTests` (усреднение по переходам с маркерами начала и конца, «ё»→«е», пропуск символов вне алфавита, пол вероятности; sanity реальных таблиц — «привет» правдоподобнее «ашду», «hello» правдоподобнее «ghbdtn»)».
- В описание `LanguageDetectorTests` добавить: «частые английские слова в русской раскладке ловятся без исключений («ашду», «ершы», «ащк»…), русские слова с редкими парами и короткие команды (`npm`, `ssh`, `grep`…) не трогаются, `wrongLayoutLLR` и явный порог».
- Фразу про бандловый список «(русская оценка их записи ≥ 0.4: «ашду» для `file`, «ершы» для `this`)» заменить на «(слова, которые пропускала прежняя побуквенная эвристика; сколько из них биграммная модель ловит сама — в спеке биграммного скоринга, §7)».
- В конец раздела добавить абзац: «Качество детектора измеряется не юнит-тестами, а `scripts/eval-detector` (наборы: токены man-страниц, проверочные половины FrequencyWords, русский словарь из NSSpellChecker; данные — в `scripts/eval-data/`, проверочные половины пересоздаёт `scripts/gen-bigrams.swift` в `.build/eval/`). Любое изменение скоринга или таблиц сопровождается прогоном `report` до и после.»

- [ ] **Step 6: Verify and commit**

Run: `swift test`
Expected: PASS.

```bash
git add CLAUDE.md
git commit -m "docs: describe bigram scoring, its tables and the evaluation tool

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
