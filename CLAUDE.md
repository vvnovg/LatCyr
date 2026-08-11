# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Что это

LatCyr — menu bar приложение для macOS: автоматически определяет текст, набранный в неправильной раскладке (Русский ↔ English), переключает раскладку и исправляет набранное. Работает как Punto Switcher. Сборка — Swift Package, без Xcode.

## Команды

```bash
swift build                          # сборка
swift test                           # все тесты
swift test --filter TextConverterTests   # один тестовый класс
swift test --filter LanguageDetectorTests/testRussianTypedInEnglishLayout  # один тест
swift run LatCyr                     # запуск из терминала (см. про разрешения ниже)
./scripts/package-app.sh             # release-сборка + упаковка в dist/LatCyr.app (ad-hoc подпись)
open dist/LatCyr.app                 # запуск собранного .app
```

**Разрешения (TCC):** при запуске через `swift run` macOS приписывает запрос разрешений терминалу, а не бинарнику LatCyr — выдача разрешения бинарнику может не сработать. Для надёжной работы нужно упаковать `.app` (`./scripts/package-app.sh`) и выдать Accessibility + Input Monitoring именно `dist/LatCyr.app` в System Settings → Privacy & Security. Повторный запуск `package-app.sh` переподписывает бандл, меняет его code hash и **сбрасывает уже выданные разрешения** — после переупаковки их нужно выдавать заново.

## Архитектура

Поток данных: `CGEventTap` ловит `keyDown` → `InputMonitor` накапливает буфер слова → на границе слова `LanguageDetector` решает «не та раскладка» → `TextFieldController` (AX API) заменяет слово, `LayoutManager` (TIS API) переключает раскладку.

Ключевой принцип изоляции: **чистые функции** (`TextConverter`, `LanguageDetector`) — без системных зависимостей, полностью юнит-тестируются; **тонкие обёртки** над системными API (`LayoutManager`, `TextFieldController`, `PermissionManager`, `InputMonitor`) — тестируются только вручную. При изменении эвристики или конвертации тесты — единственная защита, держи их зелёными.

`AppDelegate` — верхний уровень: строит меню в menu bar (иконка `character.cursor.ibeam`), включает/выключает `InputMonitor` через пункт «включено/выключено», показывает статус разрешений (✓/✗ Accessibility, Input Monitoring) и предлагает открыть настройки, если что-то не выдано. `setEnabled(true)` без `permissionManager.isFullyAuthorized` откатывается и повторно просит разрешения — не может сообщить «включено», если монитор фактически не может запуститься.

### Два пути срабатывания (гибрид)

1. **Проактивный** — на 2-м символе слова: если первые два символа — сильный сигнал другой раскладки (`LanguageDetector.proactiveSwitchSignal`), раскладка переключается сразу, а префикс заменяется (`replacePrefix`). Срабатывает только при `word.count == 2` и при `currentWord == word` (fast-typing guard: если буфер уже вырос, путь отменяется в пользу ретроактивного).
2. **Ретроактивный** — на границе слова (пробел, пунктуация, Enter, цифра, символ): `isWrongLayout` оценивает всё слово, затем `replaceLastWord` заменяет его целиком.

### Ключевые решения, которые легко сломать

- **Порядок «замена → переключение»:** `applyCorrection` сначала заменяет текст через AX, и только при успехе переключает раскладку. Не меняй порядок — переключение без успешной замены оставит пользователя в неправильной раскладке.
- **`correctionDelay` (0.05s)** в `InputMonitor`: отложенное применение даёт приложению обработать клавишу-границу до замены. Тюнинг-параметр.
- **Буфер слова:** сбрасывается на не-буквенном не-граничном символе; Backspace (keycode 51) укорачивает буфер; модификаторы (Cmd/Ctrl) и сами клавиши-модификаторы пропускаются — шорткаты не ломают буфер.
- **`isOwnApp` guard:** собственное поле приложения никогда не трогается (защита от зацикливания). Secure-поля (пароли) пропускаются.
- **`LayoutManager.flagsToModifierState`:** `UCKeyTranslate` ждёт биты `kEventKeyModifier*` (Shift = 0x0002), а не legacy Carbon-биты; эффективный Shift = shift XOR capsLock (на macOS Shift отменяет CapsLock). Смена раскладки ищет первый источник с нужным `inputSourceID` (содержит "russian" / "us", "abc", "british" и т.д.).
- **Пороги эвристики** (`russianThreshold`, `englishThreshold`, `diffThreshold`, `minWordLength`, `runPenalty`, сигнальные буквы) — настраиваются **в коде**, UI настроек в v1 нет. Слова короче 3 символов ретроактивно не исправляются.
- **Курсор после замены:** `TextFieldController.replace` сдвигает курсор на дельту длины замены, чтобы он остался после завершающего пробела — следующее слово не вставится перед ним.

## Тесты

Покрыты только чистые функции: `TextConverterTests` (двусторонняя конвертация, регистр, цифры/символы не трогаются, все 33 буквы, «ё») и `LanguageDetectorTests` (детект «ghbdtn»→привет, «руддщ»→hello, корректные слова не трогаются, короткие слова и слова с цифрами не трогаются, проактивные сигналы, скоры). Системные компоненты (CGEventTap, TIS, AX) проверяются вручную: Terminal, Safari, TextEdit, Notes, парольные поля.

## Заметки по процессу

- Коммиты — conventional style (`feat:`, `fix:`, `docs:`).
- Дизайн-документ и планы лежат в `docs/superpowers/`; рабочие артефакты SDD — в `.superpowers/sdd/`.
- `.gitignore` исключает `.build/` и `dist/` — собранные артефакты не коммитятся.
