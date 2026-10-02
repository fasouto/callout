import AnnotatorCore
import AppKit
import SwiftUI

/// The popover that asks for a replacement, the text to insert, or a comment.
@MainActor
final class MarkEditorPopover: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var completion: ((String?) -> Void)?

    /// Shows the editor. `completion` gets the entered text, or nil when cancelled.
    func show(kind: MarkKind, relativeTo rect: NSRect, of view: NSView, completion: @escaping (String?) -> Void) {
        popover?.close()
        self.completion = completion

        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MarkEditorView(kind: kind) { [weak self] value in
            self?.finish(value)
        })
        self.popover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    private func finish(_ value: String?) {
        let completion = self.completion
        self.completion = nil
        popover?.close()
        completion?(value)
    }

    // Closing by clicking elsewhere counts as cancelling.
    func popoverDidClose(_ notification: Notification) {
        popover = nil
        if let completion {
            self.completion = nil
            completion(nil)
        }
    }
}

private struct MarkEditorView: View {
    let kind: MarkKind
    let finish: (String?) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    private var prompt: String {
        switch kind {
        case .replace: "Replace with"
        case .insert: "Text to insert"
        case .comment: "Comment"
        case .delete: "Reason"
        case .keep: "Note"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(prompt, systemImage: kind.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField(prompt, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit { finish(text) }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Text("↩ save   ⌥↩ new line   esc cancel")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { finish(text) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { focused = true }
    }
}
