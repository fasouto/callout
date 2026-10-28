import AnnotatorCore
import AppKit

/// What the keys do in a review. Text typed in the document is a comment, on a
/// selection or at the caret, so the marks answer to Option and a letter. With
/// vim keys on, the letters alone are commands too, as they are in vim.
@MainActor
enum Keymap {
    private static let vimKey = "vimNavigation"

    /// Whether the document is moved through with vim's keys.
    static var usesVimKeys: Bool {
        get { UserDefaults.standard.bool(forKey: vimKey) }
        set { UserDefaults.standard.set(newValue, forKey: vimKey) }
    }

    enum Command: Equatable {
        case mark(MarkKind)
        /// The picker of saved comments.
        case snippets
        /// The overall comment.
        case overall
    }

    /// The command a key press asks for, if any: Option and a letter, or with
    /// vim keys on the plain letter. Then a lowercase k is a movement, so Keep
    /// answers to Shift-K.
    static func command(for characters: String, modifiers: NSEvent.ModifierFlags, vim: Bool = usesVimKeys) -> Command? {
        guard characters.count == 1 else { return nil }
        let plain = modifiers.isEmpty || modifiers == .shift
        guard modifiers == .option || vim && plain else { return nil }
        if vim, plain, characters == "k" { return nil }
        switch characters.lowercased() {
        case "s": return .snippets
        case "o": return .overall
        default: return MarkKind(key: characters).map(Command.mark)
        }
    }

    /// Where text typed in the document goes.
    enum Typing: Equatable {
        /// A margin field on its way to the keyboard: the keys are its.
        case field
        /// Words added to the document: after ⌥I or ⌥R, in vim's insert mode,
        /// or in the middle of words added before.
        case words
        /// A new comment: on the selection, or pinned to the caret's point.
        case comment
        /// Nowhere: the letters are movements and commands (vim's normal and visual modes).
        case nowhere
    }

    /// Where text typed now goes, worked out afresh for every key from what holds at that moment.
    nonisolated static func typing(
        fieldOnItsWay: Bool, vim: Bool, hasSelection: Bool, addingWords: Bool, insideAddedWords: Bool
    ) -> Typing {
        if fieldOnItsWay { return .field }
        if vim { return addingWords && !hasSelection ? .words : .nowhere }
        if hasSelection { return .comment }
        // Words that are in no source have no point to pin a comment to: typing there edits them.
        return addingWords || insideAddedWords ? .words : .comment
    }

    /// A command's key as shown to the user: the letter, after ⌥ unless vim keys are on.
    nonisolated static func label(_ letter: String, vim: Bool) -> String {
        vim ? letter : "⌥" + letter
    }

    enum FieldInput: Equatable {
        case key(FieldKey)
        case typing
        case shortcut
        /// An arrow, Tab or forward delete, which do nothing useful at the end
        /// of the field, and in the document would move the caret or strike text.
        case ignored
    }

    static func fieldInput(for event: NSEvent) -> FieldInput {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.contains(.command) || modifiers.contains(.control) { return .shortcut }
        switch event.keyCode {
        case KeyCode.delete:
            return .key(.deleteBackward)
        case KeyCode.escape:
            return .key(.cancel)
        case KeyCode.return, KeyCode.enter:
            // Only Option-Return is a line break in the field; Shift-Return is Return there.
            return .key(modifiers == .option ? .text("\n") : .commit)
        case KeyCode.tab, KeyCode.forwardDelete:
            return .ignored
        case let code where KeyCode.navigation.contains(code):
            return .ignored
        default:
            return .typing
        }
    }

    /// The text a key press types, if it types any: not a shortcut, a movement
    /// or a function key.
    static func typedText(of event: NSEvent) -> String? {
        guard event.modifierFlags.intersection([.command, .control]).isEmpty,
              !KeyCode.navigation.contains(event.keyCode),
              let text = event.characters, !text.isEmpty,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) })
        else { return nil }
        return text
    }
}

/// Positions in a text that vim's word and paragraph movements go to.
/// Offsets are UTF-16, as in the text view.
enum VimMotion {
    private enum Class {
        case word, space, other
    }

    private static func kind(_ unit: unichar) -> Class {
        guard let scalar = Unicode.Scalar(unit) else { return .word }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return .space }
        if CharacterSet.alphanumerics.contains(scalar) || unit == 0x5F { return .word }
        return .other
    }

    /// `w`: the start of the next word.
    static func nextWordStart(in text: NSString, from offset: Int) -> Int {
        var index = min(max(offset, 0), text.length)
        guard index < text.length else { return text.length }
        let start = kind(text.character(at: index))
        if start != .space {
            while index < text.length, kind(text.character(at: index)) == start { index += 1 }
        }
        while index < text.length, kind(text.character(at: index)) == .space { index += 1 }
        return index
    }

    /// `e`: the end of the current or the next word.
    static func wordEnd(in text: NSString, from offset: Int) -> Int {
        var index = min(max(offset, 0), text.length)
        while index < text.length, kind(text.character(at: index)) == .space { index += 1 }
        guard index < text.length else { return text.length }
        let start = kind(text.character(at: index))
        while index < text.length, kind(text.character(at: index)) == start { index += 1 }
        return index
    }

    /// `b`: the start of the current or the previous word.
    static func previousWordStart(in text: NSString, from offset: Int) -> Int {
        var index = min(max(offset, 0), text.length)
        while index > 0, kind(text.character(at: index - 1)) == .space { index -= 1 }
        guard index > 0 else { return 0 }
        let start = kind(text.character(at: index - 1))
        while index > 0, kind(text.character(at: index - 1)) == start { index -= 1 }
        return index
    }

    /// `}`: the end of this paragraph, or of the next when already there.
    static func paragraphEnd(in text: NSString, from offset: Int) -> Int {
        var index = min(max(offset, 0), text.length)
        // Step over the line break the caret may be sitting on.
        while index < text.length, text.character(at: index) == 0x0A { index += 1 }
        while index < text.length, text.character(at: index) != 0x0A { index += 1 }
        return index
    }

    /// `{`: the start of this paragraph, or of the previous when already there.
    static func paragraphStart(in text: NSString, from offset: Int) -> Int {
        var index = min(max(offset, 0), text.length)
        while index > 0, text.character(at: index - 1) == 0x0A { index -= 1 }
        while index > 0, text.character(at: index - 1) != 0x0A { index -= 1 }
        return index
    }
}
