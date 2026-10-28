import AppKit
import SwiftUI

/// A text field for writing in the margin. Built on AppKit so the keyboard can
/// be handed to it directly: SwiftUI's own focus does not reach a field inside
/// the page, which lives in a separate hosting view.
struct NoteField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var font: NSFont = .systemFont(ofSize: 12.5)
    var color: NSColor = .labelColor
    /// True when this field should have the keyboard.
    var wantsFocus = false
    var onFocusChange: (Bool) -> Void = { _ in }
    /// Called with the new text on every change, before anything else can happen.
    var onChange: (String) -> Void = { _ in }
    /// Return was pressed.
    var onCommit: () -> Void = {}
    /// Esc was pressed.
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NoteTextField {
        let field = NoteTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = 0
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.onFocusChange = { [weak coordinator = context.coordinator] focused in coordinator?.parent.onFocusChange(focused) }
        return field
    }

    func updateNSView(_ field: NoteTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder, attributes: [.font: font, .foregroundColor: NSColor.placeholderTextColor]
        )
        field.font = font
        field.textColor = color
        field.setAccessibilityLabel(placeholder)

        // Take the keyboard when asked to, once per request.
        if wantsFocus, !context.coordinator.hadFocusRequest {
            DispatchQueue.main.async { [weak field, weak coordinator = context.coordinator] in
                // Not if the request was taken back meanwhile, as by Return pressed before the field had the keyboard.
                guard let field, let window = field.window, field.currentEditor() == nil,
                      coordinator?.parent.wantsFocus == true else { return }
                window.makeFirstResponder(field)
            }
        }
        context.coordinator.hadFocusRequest = wantsFocus
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NoteTextField, context: Context) -> CGSize? {
        let width = max(proposal.width ?? 200, 40)
        guard let cell = field.cell else { return nil }
        let size = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NoteField
        var hadFocusRequest = false

        init(_ parent: NoteField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.onChange(field.stringValue)
            field.invalidateIntrinsicContentSize()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            (notification.object as? NoteTextField)?.onFocusChange?(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                // Option-Return: a line break inside the note.
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            default:
                return false
            }
        }
    }
}

final class NoteTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            onFocusChange?(true)
            // Start writing at the end rather than with everything selected.
            currentEditor()?.selectedRange = NSRange(location: stringValue.utf16.count, length: 0)
        }
        return became
    }
}
