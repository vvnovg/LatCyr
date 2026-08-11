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

The app appears in the menu bar. On first launch it asks for two permissions:

1. **Accessibility** — to read and replace text in the focused field.
2. **Input Monitoring** — to intercept keystrokes.

Grant both in System Settings → Privacy & Security, then restart the app.

## How it works

- A CGEventTap intercepts keyDown events and tracks the current word.
- On a word boundary (space, punctuation, Enter) a pure heuristic decides
  whether the word was typed in the wrong layout.
- If so, the word is replaced via the Accessibility API and the keyboard
  layout is switched via the Text Input Sources API.
- On a strong first-two-characters signal the layout is switched
  immediately (proactive mode).

## Tests

```bash
swift test
```

## Limitations (v1)

- Pure heuristic detection: no dictionary, so rare words may be missed and
  short words (<3 chars) are never corrected.
- Apps that do not expose text via the Accessibility API are skipped.
- Password fields are never touched.
