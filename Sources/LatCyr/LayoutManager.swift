import Carbon
import Foundation

/// Wraps the Text Input Sources (TIS) API: current layout, switching, and
/// keycode → character mapping.
final class LayoutManager {
    enum Layout {
        case russian
        case english
        case other
    }

    /// The current keyboard layout.
    var currentLayout: Layout {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return .other }
        return layout(of: source)
    }

    /// Whether the current layout is Russian.
    var isRussian: Bool { currentLayout == .russian }

    /// Switch the keyboard layout to Russian.
    func switchToRussian() { switchTo(layout: .russian) }

    /// Switch the keyboard layout to English.
    func switchToEnglish() { switchTo(layout: .english) }

    /// Map a keycode + modifier state to the character it produces in the
    /// current layout. Returns nil for non-printable keys.
    func character(forKeyCode keyCode: CGKeyCode, flags: CGEventFlags) -> Character? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = unsafeBitCast(layoutData, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 }

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0

        let status = UCKeyTranslate(
            layout,
            keyCode,
            UInt16(kUCKeyActionDown),
            flagsToModifierState(flags),
            0,
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).first
    }

    // MARK: - Private

    private func layout(of source: TISInputSource) -> Layout {
        guard let id = inputSourceID(source) else { return .other }
        let lower = id.lowercased()
        if lower.contains("russian") { return .russian }
        if lower.contains("us") || lower.contains("abc") || lower.contains("british")
            || lower.contains("english") || lower.contains("australian")
            || lower.contains("canadian") || lower.contains("irish")
            || lower.contains("dvorak") || lower.contains("qwerty") {
            return .english
        }
        return .other
    }

    private func inputSourceID(_ source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        let cfString = unsafeBitCast(raw, to: CFString.self)
        return cfString as String
    }

    private func switchTo(layout target: Layout) {
        guard let cfArray = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return }
        let count = CFArrayGetCount(cfArray)
        for i in 0..<count {
            guard let ptr = CFArrayGetValueAtIndex(cfArray, i) else { continue }
            let source = unsafeBitCast(ptr, to: TISInputSource.self)
            if layout(of: source) == target {
                TISSelectInputSource(source)
                return
            }
        }
    }

    private func flagsToModifierState(_ flags: CGEventFlags) -> UInt32 {
        // UCKeyTranslate expects the kEventKeyModifier* bit format (Shift =
        // 0x0002, Control = 0x0004, ...), not the legacy Carbon shiftKey/
        // alphaLock bits — the legacy bits are ignored and case is lost.
        // CapsLock toggles the effective Shift: on macOS, Shift + CapsLock
        // yields lowercase (Shift cancels CapsLock), so effective shift =
        // shift XOR capsLock.
        var state: UInt32 = 0
        let capsLock = flags.contains(.maskAlphaShift)
        let shift = flags.contains(.maskShift)
        if shift != capsLock { state |= 0x0002 }  // kEventKeyModifierShift
        if flags.contains(.maskControl) { state |= 0x0004 }  // kEventKeyModifierControl
        if flags.contains(.maskAlternate) { state |= 0x0008 }  // kEventKeyModifierOption
        if flags.contains(.maskCommand) { state |= 0x0010 }  // kEventKeyModifierCommand
        return state
    }
}
