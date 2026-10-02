import AnnotatorCore
import AppKit

/// The document view. It behaves like an editable text view, so there is a
/// caret and the keyboard can move and select, but it refuses every change:
/// letters trigger mark actions instead of typing.
final class AnnotationTextView: NSTextView {
    var onMarkKey: ((MarkKind) -> Void)?
    var onDeleteKey: (() -> Void)?
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
        case #selector(copy(_:)), #selector(selectAll(_:)):
            return super.validateUserInterfaceItem(item)
        case #selector(cut(_:)), #selector(paste(_:)), #selector(pasteAsPlainText(_:)), #selector(delete(_:)):
            return false
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    // Nothing may be dropped into the document.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }

    /// The rectangle of a character range in this view's coordinates.
    func rect(forCharacterRange range: NSRange) -> NSRect? {
        guard let window else { return nil }
        let onScreen = firstRect(forCharacterRange: range, actualRange: nil)
        guard onScreen != .zero else { return nil }
        return convert(window.convertFromScreen(onScreen), from: nil)
    }
}

enum KeyCode {
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117
    static let escape: UInt16 = 53
    /// Arrows, home, end, page up and page down.
    static let navigation: Set<UInt16> = [123, 124, 125, 126, 115, 119, 116, 121]
}
