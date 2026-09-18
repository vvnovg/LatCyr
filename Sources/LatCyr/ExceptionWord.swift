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
