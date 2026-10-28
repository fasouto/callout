import AnnotatorCore
import AppKit

/// The document view. It behaves like an editable text view, with a caret and
/// keyboard selection, but never changes its text itself. What is typed is
/// handed on, to become marks: typing comments, on the selection or pinned to
/// the caret's point; after ⌥I it adds words; Backspace strikes text out.
final class AnnotationTextView: NSTextView {
    var onCommand: ((Keymap.Command) -> Void)?
    /// Overrides the setting for this view. Nil follows Settings.
    var usesVimKeys: Bool?
    /// Text that adds words to the document.
    var onType: ((String) -> Void)?
    /// Text that starts a comment: on the selection, or pinned to the caret's point.
    var onComment: ((String) -> Void)?
    /// Backspace or forward delete at the caret, with nothing selected.
    var onDeleteCharacter: ((_ forward: Bool) -> Void)?
    /// Backspace with text selected.
    var onDeleteKey: (() -> Void)?
    /// Command-Backspace: take the mark at the caret away.
    var onRemoveMark: (() -> Void)?
    var onReturnKey: (() -> Void)?
    /// Tab moves to the next mark, Shift-Tab to the previous one.
    var onTabKey: ((_ forward: Bool) -> Void)?
    var onCancelKey: (() -> Void)?
    /// Called when a mouse selection is finished.
    var onSelectionSettled: (() -> Void)?
    /// With vim keys: called when visual mode starts or ends.
    var onVisualModeChange: ((Bool) -> Void)?
    /// Called when adding words starts or ends.
    var onAddingWordsChange: ((Bool) -> Void)?
    /// True while a margin field is on its way to the keyboard: keys belong to it.
    var isHandingKeysToField: () -> Bool = { false }
    var onFieldKey: ((FieldKey) -> Void)?
    /// Whether a caret is in the middle of words a mark added: typing there edits them.
    var isInsideAddedWords: (Int) -> Bool = { _ in false }
    /// Where pasted text comes from.
    var pasteboard = NSPasteboard.general

    /// True while a vim movement is adjusting the selection in steps; the
    /// selection only counts once it has settled.
    private(set) var isMovingByKey = false
    /// With vim keys, the fixed end of the selection in visual mode. Nil outside it.
    private var visualAnchor: Int? {
        didSet {
            if (visualAnchor == nil) != (oldValue == nil) { onVisualModeChange?(visualAnchor != nil) }
        }
    }
    /// Whether keys add words to the document: after ⌥I or ⌥R, or in vim's insert
    /// mode. Esc ends it. Without vim keys a click or a new selection ends it too,
    /// so that typing at the new caret comments again.
    private(set) var isAddingWords = false {
        didSet { if isAddingWords != oldValue { onAddingWordsChange?(isAddingWords) } }
    }
    /// The moving end of the selection: where the caret is.
    private var head = 0
    private var awaitsSecondG = false

    private var vimKeys: Bool { usesVimKeys ?? Keymap.usesVimKeys }

    /// Where text typed now goes.
    private var typing: Keymap.Typing {
        let selection = selectedRange()
        return Keymap.typing(
            fieldOnItsWay: isHandingKeysToField(), vim: vimKeys, hasSelection: selection.length > 0,
            addingWords: isAddingWords, insideAddedWords: selection.length == 0 && isInsideAddedWords(selection.location)
        )
    }

    /// Starts adding words at the caret.
    func beginAddingWords() {
        visualAnchor = nil
        isAddingWords = true
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A review opens ready for the keyboard: no click needed before the first key.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.firstResponder === window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let typing = self.typing
        if typing == .field {
            switch Keymap.fieldInput(for: event) {
            case .key(let key): onFieldKey?(key)
            // Through the input system, so accents and other composed characters work.
            case .typing: interpretKeyEvents([event])
            case .shortcut: super.keyDown(with: event)
            case .ignored: break
            }
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let characters = event.charactersIgnoringModifiers ?? ""
        let hasSelection = selectedRange().length > 0

        if isAddingWords, event.keyCode == KeyCode.escape {
            // Only stops adding words: it never cancels the review from here.
            isAddingWords = false
            return
        }
        if vimKeys, !isAddingWords, vimKeyDown(characters, keyCode: event.keyCode, modifiers: modifiers) {
            return
        }

        // ⌥ and a letter is a command, except where it adds words: there it types, accents included.
        if typing != .words, let command = Keymap.command(for: characters, modifiers: modifiers, vim: vimKeys) {
            onCommand?(command)
            visualAnchor = nil
            return
        }
        switch event.keyCode {
        case KeyCode.delete where modifiers == .command:
            onRemoveMark?()
        case KeyCode.delete, KeyCode.forwardDelete:
            if hasSelection || typing == .nowhere {
                onDeleteKey?()
            } else {
                onDeleteCharacter?(event.keyCode == KeyCode.forwardDelete)
            }
        case KeyCode.escape:
            onCancelKey?()
        case KeyCode.return, KeyCode.enter:
            if modifiers.isEmpty {
                onReturnKey?()
            } else if typing == .words, modifiers == .option || modifiers == .shift {
                // A line break in the words being added.
                onType?("\n")
            }
        case KeyCode.tab where modifiers.isEmpty || modifiers == .shift:
            onTabKey?(modifiers.isEmpty)
        default:
            if KeyCode.navigation.contains(event.keyCode) || modifiers.contains(.command) || modifiers.contains(.control) {
                // Movement, selection and shortcuts work as in any text view.
                super.keyDown(with: event)
            } else if typing != .nowhere {
                // Through the input system, so accents and other composed characters work.
                interpretKeyEvents([event])
            }
        }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        guard !text.isEmpty else { return }
        switch typing {
        case .field: onFieldKey?(.text(text))
        case .words: onType?(text)
        case .comment: onComment?(text)
        case .nowhere: break
        }
    }

    override func doCommand(by selector: Selector) {
        // Deleting goes through the marks; everything else is the text view's own business.
        switch selector {
        case #selector(deleteBackward(_:)): onDeleteCharacter?(false)
        case #selector(deleteForward(_:)): onDeleteCharacter?(true)
        case #selector(insertNewline(_:)), #selector(insertTab(_:)), #selector(insertBacktab(_:)): break
        default: super.doCommand(by: selector)
        }
    }

    /// Pasted text is added, only while adding words: anywhere else it would
    /// start a comment nobody meant. Nothing replaces a selection: that is what ⌥R is for.
    override func paste(_ sender: Any?) {
        guard typing == .words, let text = pasteboard.string(forType: .string), !text.isEmpty else {
            NSSound.beep()
            return
        }
        onType?(text)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        paste(sender)
    }

    override func mouseDown(with event: NSEvent) {
        // The superclass tracks the drag and only returns once the mouse is up.
        visualAnchor = nil
        // The caret goes somewhere new, where typing comments. Vim's insert mode ends only on Esc, as in vim.
        if !vimKeys { isAddingWords = false }
        super.mouseDown(with: event)
        onSelectionSettled?()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // Selected words are moved on to: typing on them comments. The page itself
        // only ever puts a caret, so adding words survives its redraws.
        if isAddingWords, !vimKeys, selectedRange().length > 0 { isAddingWords = false }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(cut(_:)), #selector(delete(_:)):
            return false
        case #selector(paste(_:)), #selector(pasteAsPlainText(_:)):
            return typing == .words && pasteboard.string(forType: .string) != nil
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    // Nothing may be dropped into the document.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }

    /// The rectangle of the first line of a character range, in this view's
    /// coordinates. An empty range gives the caret's rectangle.
    func rect(forCharacterRange range: NSRange) -> NSRect? {
        guard let layoutManager = textLayoutManager, let content = layoutManager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return nil }
        var result: NSRect?
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
            result = frame
            return false
        }
        let origin = textContainerOrigin
        return result?.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// Lays out the whole text, or only `ranges` of it, and returns its height.
    ///
    /// Once the whole text has been laid out at this width, the rest of it keeps
    /// its height: after a change, laying out what changed is enough. Laying out
    /// all of it again would redo whatever was let go off screen, which takes
    /// most of a second on a long document.
    func layoutHeight(ensuring ranges: [NSRange]? = nil) -> CGFloat {
        guard let layoutManager = textLayoutManager else { return 0 }
        if let ranges, let content = layoutManager.textContentManager {
            for range in ranges {
                guard let start = content.location(content.documentRange.location, offsetBy: range.location),
                      let end = content.location(start, offsetBy: range.length),
                      let textRange = NSTextRange(location: start, end: end) else { continue }
                layoutManager.ensureLayout(for: textRange)
            }
        } else {
            layoutManager.ensureLayout(for: layoutManager.documentRange)
        }
        return ceil(layoutManager.usageBoundsForTextContainer.maxY)
    }

    // MARK: - Vim keys

    /// Handles a key the vim way. Returns false for keys vim mode leaves alone.
    private func vimKeyDown(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        if modifiers == .control, characters == "r" {
            undoManager?.redo()
            return true
        }
        if keyCode == KeyCode.escape {
            // Esc leaves visual mode and lets go of the selection. It never
            // cancels the review: it is pressed too often by habit for that.
            visualAnchor = nil
            let caret = selectedRange().location
            setSelectedRange(NSRange(location: caret, length: 0))
            return true
        }
        guard modifiers.isEmpty || modifiers == .shift else { return false }
        defer { if characters != "g" { awaitsSecondG = false } }

        let text = string as NSString
        syncHead()
        switch characters {
        case "h": move(to: max(0, head - 1))
        case "l": move(to: min(text.length, head + 1))
        case "j": moveVertically(#selector(moveDown(_:)))
        case "k": moveVertically(#selector(moveUp(_:)))
        case "w": move(to: VimMotion.nextWordStart(in: text, from: head))
        case "e": move(to: VimMotion.wordEnd(in: text, from: head))
        case "b": move(to: VimMotion.previousWordStart(in: text, from: head))
        case "0": moveVertically(#selector(moveToBeginningOfLine(_:)))
        case "$": moveVertically(#selector(moveToEndOfLine(_:)))
        case "{": move(to: VimMotion.paragraphStart(in: text, from: head))
        case "}": move(to: VimMotion.paragraphEnd(in: text, from: head))
        case "G": move(to: text.length)
        case "g":
            if awaitsSecondG { move(to: 0) }
            awaitsSecondG.toggle()
        case "v":
            visualAnchor = visualAnchor == nil ? head : nil
            move(to: head)
        case "V":
            // The whole line the caret is on, and on from there.
            let line = text.lineRange(for: NSRange(location: min(head, text.length), length: 0))
            visualAnchor = line.location
            move(to: NSMaxRange(line) - (line.length > 0 && text.character(at: NSMaxRange(line) - 1) == 0x0A ? 1 : 0))
        case "u": undoManager?.undo()
        case "n": onTabKey?(true)
        case "N": onTabKey?(false)
        case "a" where visualAnchor == nil:
            // Append: start adding words after the character under the caret.
            move(to: min(text.length, head + 1))
            isAddingWords = true
        case "i" where visualAnchor == nil && selectedRange().length == 0:
            isAddingWords = true
        default: return false
        }
        return true
    }

    /// Picks up where the caret is when it was moved by something else, such as the mouse.
    private func syncHead() {
        let selection = selectedRange()
        if let anchor = visualAnchor {
            let expected = NSRange(location: min(anchor, head), length: abs(anchor - head))
            if selection == expected { return }
            visualAnchor = nil
        }
        head = selection.length > 0 && visualAnchor == nil ? NSMaxRange(selection) : selection.location
        if selection.length > 0 {
            // A selection made with the mouse can be extended from the keyboard.
            visualAnchor = selection.location
        }
    }

    private func move(to offset: Int) {
        head = min(max(offset, 0), (string as NSString).length)
        let range: NSRange
        if let anchor = visualAnchor {
            range = NSRange(location: min(anchor, head), length: abs(anchor - head))
        } else {
            range = NSRange(location: head, length: 0)
        }
        setSelectedRange(range)
        scrollRangeToVisible(NSRange(location: head, length: 0))
    }

    /// Movements that depend on how the text is laid out are left to the text
    /// view: the caret is put at the head, moved, and read back.
    private func moveVertically(_ selector: Selector) {
        isMovingByKey = true
        setSelectedRange(NSRange(location: head, length: 0))
        doCommand(by: selector)
        let moved = selectedRange().location
        isMovingByKey = false
        move(to: moved)
    }
}

enum KeyCode {
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117
    static let escape: UInt16 = 53
    static let `return`: UInt16 = 36
    static let enter: UInt16 = 76
    static let tab: UInt16 = 48
    /// Arrows, home, end, page up and page down.
    static let navigation: Set<UInt16> = [123, 124, 125, 126, 115, 119, 116, 121]
}
