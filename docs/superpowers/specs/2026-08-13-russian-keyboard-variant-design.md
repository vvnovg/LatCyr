# Поддержка вариантов русской раскладки («Russian» / «Russian - PC») — Дизайн-документ

**Дата:** 2026-08-13
**Статус:** утверждён

## 1. Цель

Исправить неверную конвертацию для пользователей с активной macOS-раскладкой **«Russian»** (`com.apple.keylayout.Russian`, «собственная» раскладка Apple без суффикса «-PC»): три клавиши (`` ` ``/`~`, `\`/`|`, `/`) конвертируются неверно, потому что `TextConverter.latinToCyrillic` жёстко зашит под раскладку **«Russian - PC»** (`com.apple.keylayout.RussianWin`, стандартный виндовый ЙЦУКЕН). `LayoutManager` при этом не различает варианты русской раскладки — обе распознаются одинаково как `.russian`.

Заодно чинится смежный баг: `LayoutManager.layout(of:)` определяет русскую раскладку по вхождению подстроки `"russian"` в input source ID, из-за чего белорусская раскладка (`com.apple.keylayout.Byelorussian`) тоже ошибочно распознаётся как русская.

## 2. Диагностика (root cause)

Физическая проверка на реальном Mac (Apple Magic Keyboard, раскладка «Russian») дала:

| Клавиша (US layout) | В коде сейчас (`latinToCyrillic`) | Реально на «Russian» |
|---|---|---|
| `` ` `` / `~` | → ё / Ё | → `]` / `[` (не буква) |
| `\` / `\|` | не замаплена | → ё / Ё |
| `/` / `?` | → `.` / (нет записи) | → `/` / `?` (без изменений) |

Остальные 26 буквенных клавиш (`q`–`p`, `a`–`l`, `z`–`m`) и `[`/`]` совпадают между вариантами полностью — расхождение изолировано ровно в этих трёх клавишах.

Через `TISCreateInputSourceList` установлены точные ID:

| ID | Название в System Settings |
|---|---|
| `com.apple.keylayout.Russian` | Russian |
| `com.apple.keylayout.RussianWin` | Russian – PC |
| `com.apple.keylayout.Russian-Phonetic` | Russian – QWERTY |

`com.apple.keylayout.Byelorussian` — Belarusian; содержит подстроку `"russian"`, из-за чего `LayoutManager.layout(of:)` (проверка `lower.contains("russian")`) ошибочно относит её к `.russian`.

## 3. Требования

- Раскладка `com.apple.keylayout.Russian` («Russian») должна конвертироваться и определяться как граница слова корректно, по данным диагностики.
- Раскладка `com.apple.keylayout.RussianWin` («Russian - PC») — без изменений (текущее поведение уже верно).
- Любая другая раскладка, чей ID распознаётся как русская (включая `Russian-Phonetic` и будущие варианты Apple), но не является точно `com.apple.keylayout.Russian`, — использует PC-таблицу (текущее поведение) как fallback. Для неё нет данных диагностики, специально не поддерживается в этой итерации.
- `Byelorussian` (и любая другая небелорусская-нерусская раскладка, случайно содержащая подстроку «russian») не должна больше распознаваться как русская.
- `TextConverter` остаётся чистой функцией без системных зависимостей — вариант раскладки передаётся параметром, а не читается изнутри.

## 4. Архитектура

### `TextConverter`

Новый публичный тип:

```swift
public enum RussianKeyboardVariant: Equatable {
    case pc     // "Russian - PC" (RussianWin) — Windows-стандартный ЙЦУКЕН
    case apple  // "Russian" (Apple) — собственная раскладка Apple
}
```

Таблица делится на общую часть (26 букв + `[`/`]`, идентичны в обоих вариантах) и два оверлея, которые мёржатся в зависимости от варианта:

```swift
private static let sharedLatinToCyrillic: [Character: Character] = [
    "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е", "y": "н",
    "u": "г", "i": "ш", "o": "щ", "p": "з", "[": "х", "]": "ъ",
    "a": "ф", "s": "ы", "d": "в", "f": "а", "g": "п", "h": "р",
    "j": "о", "k": "л", "l": "д", ";": "ж", "'": "э",
    "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и", "n": "т",
    "m": "ь", ",": "б", ".": "ю",
]

private static let pcOverlay: [Character: Character] = ["`": "ё", "~": "Ё", "/": "."]
private static let appleOverlay: [Character: Character] = ["\\": "ё", "|": "Ё"]
```

`toCyrillic`/`toLatin` получают обязательный параметр:

```swift
public static func toCyrillic(_ text: String, variant: RussianKeyboardVariant) -> String
public static func toLatin(_ text: String, variant: RussianKeyboardVariant) -> String
```

`ambiguousLetterSymbols` (сейчас статическая константа) становится функцией от варианта:

```swift
public static func ambiguousLetterSymbols(for variant: RussianKeyboardVariant) -> Set<Character> {
    let base: Set<Character> = [",", ".", ";", "'", "[", "]"]
    return variant == .pc ? base.union(["`"]) : base.union(["\\"])
}
```

(`/` не входит ни в один из наборов — в обоих вариантах она либо не буква (`.pc`: маппится на `.`, тоже не буква), либо не меняется вообще (`.apple`) — как и в текущем поведении.)

### `LayoutManager`

Правка детекции (убирает false-positive на Byelorussian):

```swift
// было: if lower.contains("russian") { return .russian }
if lower.hasPrefix("com.apple.keylayout.russian") { return .russian }
```

Новое вычисляемое свойство:

```swift
var currentRussianVariant: TextConverter.RussianKeyboardVariant {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let id = inputSourceID(source) else { return .pc }
    return id == "com.apple.keylayout.Russian" ? .apple : .pc
}
```

### `LanguageDetector.isWrongLayout`

Новый обязательный параметр `variant: TextConverter.RussianKeyboardVariant`, используется в guard-проверке «буква или неоднозначный символ» (через `ambiguousLetterSymbols(for: variant)`) и при вычислении `converted` (через `toLatin(_:variant:)`/`toCyrillic(_:variant:)`).

### `InputMonitor`

Новое поле `currentRussianVariant: TextConverter.RussianKeyboardVariant`, захватывается в тот же момент, что и `currentLayoutIsRussian` (когда начинается новое слово — `if currentWord.isEmpty { ... }`). Прокидывается везде, где сейчас прокидывается `wasRussian`:
- в оба метода планирования коррекции (`scheduleProactiveCheck`, `scheduleRetroactiveCheck`) — захватывается локальной константой рядом с `wasRussian`;
- в `applyCorrection` — используется вместо текущего implicit `TextConverter.toLatin(word)`/`toCyrillic(word)`;
- в классификации символа буфера (`char.isLetter || TextConverter.ambiguousLetterSymbols.contains(char)`) — через `ambiguousLetterSymbols(for: currentRussianVariant)`;
- в вызов `LanguageDetector.isWrongLayout` — передаётся `variant: currentRussianVariant`.

Путь одиночного символа `/` (`performLeadingCharCheck`, `proactiveSingleCharSwitchSignal`) вариант не использует — он не трогает `TextConverter` вообще (только переключает раскладку, без замены текста), остаётся без изменений.

### `TextFieldController`

`captureWordAnchor`, `replaceAnchoredWord`, `replacePrefix` получают параметр `variant: TextConverter.RussianKeyboardVariant` — нужен их общему приватному `isBoundary`, который тоже зависит от варианта (граница слова в реальном тексте документа определяется так же, как граница в буфере `InputMonitor`).

## 5. Тестирование

`TextConverterTests`: все существующие тесты обновляются на явный `variant: .pc` (сохраняет текущее покрытие для «Russian - PC»). Новые тесты для `.apple`: круговая конвертация всех 33 букв под `.apple`-таблицей, отдельно — `` ` ``/`\` не путаются между вариантами (например `toCyrillic("\\", variant: .pc)` не должно давать «ё», а `toCyrillic("`", variant: .apple)` не должно давать «ё»).

`LanguageDetectorTests`: все существующие вызовы `isWrongLayout` обновляются на `variant: .pc` (без изменения семантики теста). Новый тест: слово, набранное в раскладке `.apple` с использованием клавиши `\` (например «ё» как первая буква слова), детектируется корректно при `.apple`, но не детектируется (или детектируется неверно) при `.pc` — подтверждает, что параметр действительно на что-то влияет, а не игнорируется.

`LayoutManager`, `InputMonitor`, `TextFieldController` — тонкие системные обёртки, тестируются вручную (см. существующую конвенцию проекта): переключить раскладку на «Russian», набрать слово с использованием клавиши `\`/`ё` в неправильной раскладке, убедиться в корректной коррекции; отдельно проверить, что «Russian - PC» не сломалась (регресс).

## 6. Границы (out of scope)

- `Russian-Phonetic` и любые другие нестандартные русские раскладки Apple — используют PC-таблицу как fallback, без гарантии корректности. Отдельная итерация, если появятся жалобы.
- Раскладки не от Apple (сторонние Cyrillic-раскладки, если такие ставятся) — не рассматриваются, `currentRussianVariant` вернёт `.pc` по умолчанию.
- Смена раскладки Apple → добавление ещё одного собственного варианта в будущих версиях macOS — не отслеживается автоматически, потребует ручного добавления при обнаружении.
