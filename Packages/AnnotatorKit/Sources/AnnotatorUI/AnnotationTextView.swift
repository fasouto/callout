import AnnotatorCore
import AppKit

/// The document view. It behaves like an editable text view, so there is a
/// caret and the keyboard can move and select, but it refuses every change:
/// letters trigger mark actions instead of typing.
final class AnnotationTextView: NSTextView {
    var onMarkKey: ((MarkKind) -> Void)?
    var onDeleteKey: (() -> Void)?
    var onReturnKey: (() -> Void)?
    /// Tab moves to the next mark, Shift-Tab to the previous one.
    var onTabKey: ((_ forward: Bool) -> Void)?
    var onCancelKey: (() -> Void)?
    /// Called when a mouse selection is finished.
    var onSelectionSettled: (() -> Void)?

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        false
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])

        if modifiers.isEmpty || modifiers == .shift,
           let key = event.charactersIgnoringModifiers, let kind = MarkKind(key: key) {
            onMarkKey?(kind)
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
