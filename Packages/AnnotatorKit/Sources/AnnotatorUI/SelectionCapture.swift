import AppKit
import ApplicationServices

/// Gets the text selected in whatever app is in front, by pressing ⌘C for the
/// user and then putting the clipboard back the way it was.
@MainActor
enum SelectionCapture {
    /// Posting key presses to other apps needs the Accessibility permission.
    static var isAllowed: Bool {
        AXIsProcessTrusted()
    }

    /// Asks macOS to show its permission prompt and list the app in Accessibility settings.
    static func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// The selected text, or nil when nothing was copied.
    static func capture() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = SavedPasteboard(pasteboard)
        let before = pasteboard.changeCount

        // The shortcut's own modifiers are still down; ⌥⌘C would not be a copy.
        for _ in 0..<30 where !modifiersAreUp() {
            try? await Task.sleep(for: .milliseconds(20))
        }
        pressCopy()

        var text: String?
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(20))
            if pasteboard.changeCount != before {
                text = pasteboard.string(forType: .string)
                break
            }
        }
        if pasteboard.changeCount != before { saved.restore(to: pasteboard) }
        return text
    }

    private static func modifiersAreUp() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return flags.intersection([.maskAlternate, .maskControl, .maskShift, .maskCommand]).isEmpty
    }

    private static func pressCopy() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyC: CGKeyCode = 8
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: isDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}

/// Everything on a pasteboard, so it can be put back.
@MainActor
struct SavedPasteboard {
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let copies = items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !copies.isEmpty { pasteboard.writeObjects(copies) }
    }
}
