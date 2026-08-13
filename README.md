# LatCyr

Menu bar приложение для macOS: автоматически определяет текст, набранный в неправильной раскладке (Русский ↔ English), переключает раскладку и исправляет набранное. Работает как Punto Switcher.

## Скачать тестовую сборку

**[LatCyr.zip — последняя тестовая сборка](https://github.com/vvnovg/LatCyr/releases/latest)**

Не релиз, версии нет — сборки помечены коммитом, с которого собраны. Инструкция по установке и выдаче разрешений — в описании релиза.

## Сборка из исходников

Swift Package, без Xcode:

```bash
swift build                          # сборка
swift test                           # тесты
./scripts/package-app.sh             # release-сборка + упаковка в dist/LatCyr.app
open dist/LatCyr.app
```

Подробности архитектуры и ключевые решения — в [CLAUDE.md](CLAUDE.md).
