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
