import AppKit
import CoreGraphics

/// Читает текущее выделение фронтального приложения через буфер обмена —
/// для случаев, где это не умеет AX: в терминалах и Electron-приложениях
/// видимый текст не является читаемым AX-значением, и
/// kAXSelectedTextAttribute приходит пустым. Cmd+C обрабатывает само
/// приложение, поэтому путь работает везде, где есть команда «Копировать».
///
/// Тонкая обёртка над NSPasteboard и CGEvent, как KeystrokeSimulator:
/// чистой логики нет, проверяется вручную, а не юнит-тестами.
final class ClipboardReader {
    /// kVK_ANSI_C.
    private static let cKeyCode: CGKeyCode = 8

    /// Действие пункта меню срабатывает в момент закрытия меню, а фокус
    /// возвращается приложению не мгновенно: Cmd+C, посланный раньше,
    /// уйдёт в закрывающееся меню. Тюнинг-параметр, как
    /// InputMonitor.correctionDelay.
    private let focusRestoreDelay: TimeInterval = 0.1

    /// Шаг опроса changeCount.
    private let pollInterval: TimeInterval = 0.02

    /// Сколько ждать ответа приложения на Cmd+C, прежде чем сдаться.
    private let copyTimeout: TimeInterval = 0.5

    /// Постит синтетический Cmd+C, отдаёт скопированную строку в
    /// `completion` и восстанавливает прежнее содержимое буфера обмена.
    /// `nil` — приложение не ответило за `copyTimeout` либо положило в
    /// буфер не-текст. `completion` всегда вызывается на главной очереди.
    func copySelection(completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotItems(of: pasteboard)
        let changeCountBefore = pasteboard.changeCount

        DispatchQueue.main.asyncAfter(deadline: .now() + focusRestoreDelay) {
            guard self.postCopyChord() else {
                completion(nil)
                return
            }
            let deadline = Date().addingTimeInterval(self.copyTimeout)
            self.waitForChange(from: changeCountBefore, deadline: deadline) { changed in
                guard changed else {
                    // Ничего не пришло: в буфере лежит ровно то, что лежало,
                    // и восстановление только затёрло бы содержимое, которое
                    // приложение-владелец отдаёт лениво.
                    completion(nil)
                    return
                }
                let text = pasteboard.string(forType: .string)
                self.restore(snapshot, to: pasteboard)
                // Пустую строку трактуем как отсутствие текста — так же,
                // как это делает TextFieldController.selectedText().
                completion((text?.isEmpty ?? true) ? nil : text)
            }
        }
    }

    // MARK: - Private

    /// Глубокая копия: после clearContents() живые NSPasteboardItem
    /// становятся недействительными, поэтому данные всех типов нужно
    /// материализовать сейчас.
    private func snapshotItems(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }

    private func postCopyChord() -> Bool {
        // Оба события конструируются до отправки любого из них, чтобы
        // сбой на keyUp не оставил непарный keyDown.
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: Self.cKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: Self.cKeyCode, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // InputMonitor.handle пропускает события с этой меткой, поэтому наш
        // собственный event tap не заведёт синтетический Cmd+C в буфер слова.
        down.setIntegerValueField(.eventSourceUserData, value: KeystrokeSimulator.eventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: KeystrokeSimulator.eventMarker)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    /// Опрос changeCount через очередь, а не через сон: run loop должен
    /// продолжать крутиться, чтобы меню дозакрылось, а фокус вернулся в
    /// приложение, которому мы только что послали Cmd+C.
    private func waitForChange(
        from changeCountBefore: Int,
        deadline: Date,
        completion: @escaping (Bool) -> Void
    ) {
        if NSPasteboard.general.changeCount != changeCountBefore {
            completion(true)
            return
        }
        guard Date() < deadline else {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            self.waitForChange(from: changeCountBefore, deadline: deadline, completion: completion)
        }
    }
}
