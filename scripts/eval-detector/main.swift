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
