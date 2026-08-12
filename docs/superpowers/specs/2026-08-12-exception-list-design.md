# Слова-исключения и гибридные приложения — Дизайн-документ

**Дата:** 2026-08-12
**Статус:** утверждён

## 1. Цель

Два связанных расширения детекции LatCyr:

1. **Слова-исключения** — список слов, которые эвристика (`LanguageDetector`) никогда не конвертирует, если они набраны правильно, и всегда конвертирует, если набраны в чужой раскладке, — независимо от весовых коэффициентов и порогов (`russianThreshold`, `englishThreshold`, `diffThreshold`). Нужны для IT-терминов (`http`, `www`, `ssl`, `sdd`, `usb` и т.п.), которые нормальная частотная эвристика оценивает ненадёжно (короткие, нетипичное распределение согласных/гласных). Список предзаполнен и расширяется пользователем через меню.
2. **Гибридные приложения** — расширяемый список bundle identifiers приложений, где обычная AX-замена текста не работает (как в терминалах — рендер, а не редактируемая AX-строка) и должен применяться keystroke-fallback механизм, уже реализованный для Terminal.app/iTerm2.

## 2. Требования

- Слово-исключение может быть **любого языка** — кириллическое или латинское. Смешение алфавитов в одном слове не поддерживается.
- Проверка исключений действует **только на ретроактивном пути** (граница слова, полное слово уже известно). Проактивные пути (2-символьный сигнал, `/`-сигнал в терминале) не меняются — физически не могут сверяться со словом-исключением, зная только 1–2 символа.
- Базовый список слов-исключений (английские IT-термины) поставляется вместе с `.app` и доступен из коробки.
- Пользователь дополняет список исключений через пункт меню, читающий текущее AX-выделение.
- Список гибридных приложений начинается пустым (терминалы уже жёстко заданы в коде) и дополняется через пункт меню, читающий текущее фронтальное приложение.
- Оба динамических списка переживают переустановку `.app` (`package-app.sh` сбрасывает TCC-разрешения при каждой пересборке — списки этой проблемы иметь не должны).

## 3. Архитектура

### Новые компоненты

Оба — тонкие обёртки над файловой системой (по аналогии с `PermissionManager`), без чистой логики; тестируются вручную, не юнит-тестами.

**`ExceptionStore`**
```swift
final class ExceptionStore {
    private(set) var words: Set<String> = []   // объединение bundled + dynamic, lowercase

    func load()                                 // читает оба файла при старте
    func contains(_ word: String) -> Bool
    @discardableResult func add(_ word: String) -> Bool  // false если уже есть
}
```
- Бандловый файл: `Bundle.main.resourceURL?.appendingPathComponent("exceptions.txt")` — присутствует только в упакованном `.app`, отсутствует при `swift run` (ожидаемо, аналогично отсутствию TCC-разрешений в dev-режиме, см. CLAUDE.md).
- Динамический файл: `~/Library/Application Support/LatCyr/exceptions.txt`.
- `load()` читает оба (какие есть), объединяет в `words`.
- `add(_:)` дописывает строку в динамический файл (создаёт каталог/файл при отсутствии), обновляет `words` в памяти. Не пишет дубликат.

**`HybridAppStore`**
```swift
final class HybridAppStore {
    private(set) var bundleIDs: Set<String> = []   // только dynamic, без бандлового дефолта

    func load()
    func contains(_ bundleID: String) -> Bool
    @discardableResult func add(_ bundleID: String) -> Bool
}
```
- Динамический файл: `~/Library/Application Support/LatCyr/hybrid-apps.txt`.
- Терминалы (`com.apple.Terminal`, `com.googlecode.iterm2`) остаются жёстко заданы в `KeystrokeSimulator.terminalBundleIDs` — не дублируются сюда.

### Переименование `KeystrokeSimulator.isTerminalFrontmost`

После добавления гибридных приложений свойство означает не только «известный терминал», а «терминал ИЛИ зарегистрированное гибридное приложение». Переименовывается в `usesKeystrokeFallback`:

```swift
final class KeystrokeSimulator {
    private let hybridAppStore: HybridAppStore
    init(hybridAppStore: HybridAppStore) { self.hybridAppStore = hybridAppStore }

    var usesKeystrokeFallback: Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return Self.terminalBundleIDs.contains(id) || hybridAppStore.contains(id)
    }
}
```
Оба вызова в `InputMonitor` (`performLeadingCharCheck`, `applyCorrection`) переименовываются на новое имя без изменения логики.

### Владение и передача

`InputMonitor` создаёт `ExceptionStore` и `HybridAppStore`, вызывает `load()` при создании (или в `start()`), передаёт `HybridAppStore` в `KeystrokeSimulator`. `AppDelegate` держит собственные ссылки на те же два store (передаются в конструктор `AppDelegate` вместе с `InputMonitor`, либо `InputMonitor` их экспонирует как `let`-свойства) — нужны для новых пунктов меню.

## 4. Интеграция в детекцию

`LanguageDetector.isWrongLayout` получает новый обязательный параметр `exceptions: Set<String>`. Проверка не зависит от направления раскладки — работает симметрично для кириллических и латинских исключений:

```swift
public static func isWrongLayout(
    word: String, currentLayoutIsRussian: Bool, exceptions: Set<String>
) -> Bool {
    let lower = word.lowercased()
    guard lower.count >= minWordLength else { return false }
    guard lower.allSatisfy({ $0.isLetter || TextConverter.ambiguousLetterSymbols.contains($0) }) else { return false }

    if exceptions.contains(lower) { return false }  // само слово — исключение → никогда не трогать

    let converted = currentLayoutIsRussian ? TextConverter.toLatin(lower) : TextConverter.toCyrillic(lower)
    if exceptions.contains(converted) { return true }  // конверсия — исключение → всегда исправить

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

`minWordLength` (3) применяется раньше проверки исключений — исключение короче 3 символов ретроактивно не сработает. Все дефолтные примеры (`http`, `www`, `ssl`, `sdd`, `usb`) длиннее порога, конфликта нет.

`InputMonitor.handle()` передаёт `exceptionStore.words` в единственный вызов `LanguageDetector.isWrongLayout` (в ветке `else if` на границе слова).

## 5. UI в меню

Два новых пункта в `AppDelegate.buildMenu()`, оба — модальные `NSAlert` для обратной связи (как `promptForPermissions()`), активны независимо от состояния «включено/выключено».

### «Добавить выделенное в исключения»

1. `TextFieldController` получает метод:
   ```swift
   func selectedText() -> String?
   ```
   Читает `kAXSelectedTextAttribute` фокусированного элемента через `focusedTextElement()`; пропускает secure-поля (`isSecure`) — как остальные операции контроллера. Возвращает `nil`, если нет фокуса, нет AX-доступа к выделению или это secure-поле.
2. Валидация: строка после `trim` непуста и состоит **целиком** из букв одного алфавита — либо только кириллица, либо только латиница (без цифр/пунктуации/пробелов/смешения).
3. Если валидация не прошла → алерт «Выделите слово на одном языке — русском или английском».
4. Если `selectedText()` вернул `nil` → алерт «Не удалось прочитать выделение. В терминалах и некоторых приложениях это не поддерживается».
5. Иначе `exceptionStore.add(text.lowercased())`:
   - слово добавлено → алерт «Добавлено в исключения: http»;
   - уже было в списке → алерт «Уже в списке исключений: http».

### «Добавить текущее приложение как гибридное»

1. Берёт `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`. LSUIElement-приложения (как LatCyr) не перехватывают фокус при клике по строке меню, поэтому фронтальным остаётся то приложение, где пользователь печатал.
2. Если bundle ID отсутствует → алерт «Не удалось определить текущее приложение».
3. Если bundle ID совпадает с `com.latcyr.app` или уже входит в `KeystrokeSimulator.terminalBundleIDs` / `hybridAppStore` → алерт «Уже поддерживается: Visual Studio Code (com.microsoft.VSCode)».
4. Иначе `hybridAppStore.add(bundleID)` → алерт «Добавлено как гибридное: Visual Studio Code (com.microsoft.VSCode)» (имя приложения — `NSWorkspace.shared.frontmostApplication?.localizedName`).

## 6. Файлы: формат, расположение, дефолтный список

**Формат** (оба файла, `exceptions.txt` и `hybrid-apps.txt`): простой текст, одно значение на строку. Строки, начинающиеся с `#`, и пустые строки игнорируются. При чтении значения приводятся к нижнему регистру.

**Расположение:**
| Файл | Путь | Источник |
|---|---|---|
| Бандловый список слов | `Sources/LatCyr/Resources/exceptions.txt` (репозиторий) → `dist/LatCyr.app/Contents/Resources/exceptions.txt` | копируется `package-app.sh`, read-only в рантайме |
| Динамический список слов | `~/Library/Application Support/LatCyr/exceptions.txt` | создаётся при первом `add()` |
| Динамический список гибридных app | `~/Library/Application Support/LatCyr/hybrid-apps.txt` | создаётся при первом `add()` |

`package-app.sh` дополняется командой копирования `Resources/exceptions.txt` в `Contents/Resources/` — аналогично копированию бинарника.

**Перечитывание:** оба файла читаются один раз при старте `InputMonitor`/`AppDelegate`. Добавление через меню сразу обновляет и файл, и in-memory `Set`. Внешняя правка динамического файла (например, в Finder) применяется только после перезапуска (переключение «выключено/включено» не перечитывает — только полный перезапуск приложения). Это принятое ограничение v1, не баг.

**Дефолтный список `exceptions.txt`** (английские IT-термины и протоколы, финальный список подлежит правке при ревью):
```
http https www ssl tls ssh ftp sftp dns vpn tcp udp
api sdk sdd ide cli gui ui ux cpu gpu ram rom usb hdd ssd
json xml html css sql nosql git svn npm pip docker kubernetes
oauth jwt rest soap grpc cdn dom ajax spa
```

## 7. Тестирование

`ExceptionStore` и `HybridAppStore` — тонкие обёртки над файловым I/O, тестируются вручную (как `PermissionManager`, `KeystrokeSimulator`), не входят в юнит-тесты.

`LanguageDetectorTests`: сигнатура `isWrongLayout` меняется — все существующие вызовы обновляются на `exceptions: []`. Новые тесты:
- латинское исключение (`http`), набранное в английской раскладке правильно → `isWrongLayout` возвращает `false`, даже если бы обычная эвристика посчитала слово нерусским/неанглийским пограничным случаем;
- то же исключение, набранное в русской раскладке (получится кириллическая абракадабра, `toLatin()` от которой равен `http`) → `isWrongLayout` возвращает `true`, даже если скор не проходит обычные пороги;
- симметрично — кириллическое исключение, набранное в английской раскладке по ошибке → принудительно исправляется;
- слово короче `minWordLength`, даже совпадающее с исключением, — не обрабатывается (ранний `guard` отрабатывает раньше проверки исключений).

## 8. Границы (out of scope v1)

- Живое отслеживание изменений файлов (FSEvents) — не реализуется, см. раздел 6.
- Смешение алфавитов в одном слове-исключении — не поддерживается.
- UI-редактор списка (таблица в отдельном окне) — не входит; редактирование вручную через Finder остаётся доступным.
- Приоритет исключения не настраивается — правило безусловно, порогов/весов не имеет.
