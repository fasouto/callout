import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier flags (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    var modifiers: UInt32
    /// The key's label, for display.
    var key: String

    static let `default` = Hotkey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey | cmdKey), key: "A")

    /// The shortcut the way menus write it, such as ⌥⌘A.
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + key
    }

    /// The shortcut a key press describes, or nil when it has no ⌘, ⌥ or ⌃:
    /// a plain letter would take that letter away from every app.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        guard modifiers & UInt32(controlKey | optionKey | cmdKey) != 0,
              let key = event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: Self.label(for: event.keyCode) ?? key)
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    private static func label(for keyCode: UInt16) -> String? {
        switch Int(keyCode) {
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Delete: "⌫"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        default: nil
        }
    }

    // MARK: Stored choice

    private static let defaultsKey = "captureHotkey"

    static var stored: Hotkey {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let hotkey = try? JSONDecoder().decode(Hotkey.self, from: data) else { return .default }
            return hotkey
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey)
        }
    }
}

/// Registers the shortcut with the system. Carbon's hot keys need no permission
/// and work while another app is in front.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    var onPress: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Registers `hotkey`, replacing the current one. Returns false when the
    /// system refuses it, usually because another app already has it.
    @discardableResult
    func register(_ hotkey: Hotkey) -> Bool {
        unregister()
        if handlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), hotkeyPressed, 1, &eventType, nil, &handlerRef)
        }
        // "ANNO"
        let identifier = EventHotKeyID(signature: 0x414E_4E4F, id: 1)
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    fileprivate func pressed() {
        onPress?()
    }
}

private func hotkeyPressed(_: EventHandlerCallRef?, _: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    DispatchQueue.main.async {
        MainActor.assumeIsolated { HotkeyCenter.shared.pressed() }
    }
    return noErr
}
