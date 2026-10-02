import AnnotatorCore
import AppKit

/// The document view. It behaves like an editable text view, so there is a
/// caret and the keyboard can move and select, but it refuses every change:
/// letters trigger commands instead of typing.
final class AnnotationTextView: NSTextView {
    var onCommand: ((Keymap.Command) -> Void)?
    /// Overrides the setting for this view. Nil follows Settings.
    var usesVimKeys: Bool?
    var onDeleteKey: (() -> Void)?
    var onReturnKey: (() -> Void)?
    /// Tab moves to the next mark, Shift-Tab to the previous one.
    var onTabKey: ((_ forward: Bool) -> Void)?
    var onCancelKey: (() -> Void)?
    /// Called when a mouse selection is finished.
    var onSelectionSettled: (() -> Void)?
    /// With vim keys: called when visual mode starts or ends.
    var onVisualModeChange: ((Bool) -> Void)?

    /// True while a vim movement is adjusting the selection in steps; the
    /// selection only counts once it has settled.
    private(set) var isMovingByKey = false
    /// With vim keys, the fixed end of the selection in visual mode. Nil outside it.
    private var visualAnchor: Int? {
        didSet {
            if (visualAnchor == nil) != (oldValue == nil) { onVisualModeChange?(visualAnchor != nil) }
        }
    }
    /// The moving end of the selection: where the caret is.
    private var head = 0
    private var awaitsSecondG = false

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        false
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let characters = event.charactersIgnoringModifiers ?? ""
        let isPlain = modifiers.isEmpty || modifiers == .shift

        let vim = usesVimKeys ?? Keymap.usesVimKeys
        if vim, vimKeyDown(characters, keyCode: event.keyCode, modifiers: modifiers) { return }

        if isPlain, let command = Keymap.command(for: characters, vim: vim) {
            onCommand?(command)
            visualAnchor = nil
            return
        }
        switch event.keyCode {
        case KeyCode.delete, KeyCode.forwardDelete:
            onDeleteKey?()
        case KeyCode.escape:
            onCancelKey?()
        case KeyCode.return, KeyCode.enter where modifiers.isEmpty:
            onReturnKey?()
        case KeyCode.tab where modifiers.isEmpty || modifiers == .shift:
            onTabKey?(modifiers.isEmpty)
        default:
            // Movement and selection keys keep working; anything that would type is dropped.
            if KeyCode.navigation.contains(event.keyCode) || modifiers.contains(.command) || modifiers.contains(.control) {
                super.keyDown(with: event)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        // The superclass tracks the drag and only returns once the mouse is up.
        visualAnchor = nil
        super.mouseDown(with: event)
        onSelectionSettled?()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(cut(_:)), #selector(paste(_:)), #selector(pasteAsPlainText(_:)), #selector(delete(_:)):
            return false
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

    /// Lays out the whole text and returns its height.
    func layoutHeight() -> CGFloat {
        guard let layoutManager = textLayoutManager else { return 0 }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
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
