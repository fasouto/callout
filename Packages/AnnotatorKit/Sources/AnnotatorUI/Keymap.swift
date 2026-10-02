import AnnotatorCore
import AppKit

/// What the keys do in a review. Letters are never typed into the document, so
/// each one can be a command.
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

    /// The command a plain key press asks for, if any. With vim keys on, a
    /// lowercase k is a movement, so Keep answers to Shift-K only.
    static func command(for characters: String, vim: Bool = usesVimKeys) -> Command? {
        guard characters.count == 1 else { return nil }
        if vim, characters == "k" { return nil }
        switch characters.lowercased() {
        case "s": return .snippets
        case "o": return .overall
        default: return MarkKind(key: characters).map(Command.mark)
        }
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
