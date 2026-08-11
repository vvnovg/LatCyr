# LatCyr

macOS menu bar app that auto-detects text typed in the wrong keyboard layout
(Russian ↔ English), switches the layout, and fixes the typed text.

## Build

```bash
swift build
```

## Run

```bash
swift run LatCyr
```

The app is a menu-bar-only app (no Dock icon) with a `character.cursor.ibeam`
icon. On first launch, if permissions are missing, it shows an alert and
opens System Settings. The menu itself shows:

- A toggle — **LatCyr включено / выключено** — to enable/disable correction
  without quitting the app.
- Live permission status — **✓/✗ Accessibility** and **✓/✗ Input
  Monitoring**.
- **Открыть настройки разрешений…** — jumps straight to the Privacy &
  Security pane.

The two required permissions:

1. **Accessibility** — to read and replace text in the focused field.
2. **Input Monitoring** — to intercept keystrokes.

Grant both in System Settings → Privacy & Security, then restart the app.
The toggle refuses to report "enabled" while either permission is missing.

> **Note:** when run via `swift run` from a terminal, macOS attributes the
> permission request to the terminal (the "responsible process"), not to the
> LatCyr binary — so granting the binary alone may not work. For reliable
> permissions, package as a proper `.app` bundle (below).

## Package as .app (recommended)

A bundled app has its own TCC identity, so permissions apply to LatCyr.app
itself and work regardless of how it is launched.

```bash
./scripts/package-app.sh   # builds release + packages dist/LatCyr.app (ad-hoc signed)
open dist/LatCyr.app
```

Then grant both permissions to `dist/LatCyr.app` in System Settings →
Privacy & Security (Accessibility and Input Monitoring), and relaunch.

> Re-running `package-app.sh` re-signs the bundle, which changes its code hash
> and drops already-granted permissions — re-grant after re-packaging.

## How it works

- A CGEventTap intercepts keyDown events and tracks the current word.
- On a word boundary (space, punctuation, digit, Enter) a pure heuristic
  decides whether the word was typed in the wrong layout.
- If so, the word is replaced via the Accessibility API and the keyboard
  layout is switched via the Text Input Sources API.
- On a strong first-two-characters signal the layout is switched
  immediately (proactive mode).
- Correction never touches LatCyr's own UI or password (secure) fields.
- Quit from the menu (**Выход**) or `Cmd+Q`.

## Tests

```bash
swift test
```

## Limitations (v1)

- Pure heuristic detection: no dictionary, so rare words may be missed and
  short words (<3 chars) are never corrected.
- Apps that do not expose text via the Accessibility API are skipped.
- Password fields are never touched.
