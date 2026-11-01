import CalloutCore
import CalloutStore
import AppKit
import SwiftUI

extension SnippetContext {
    /// The context whose snippets come first for a review of this origin.
    static func preferred(for request: ReviewRequest) -> SnippetContext {
        switch request.origin {
        case .planHook, .lastReply: .plans
        case .agentRequest, .fileDrop, .share: .documents
        case .hotkey, .service: .gitlab
        }
    }
}

/// The quick picker for reusable comments, shown at the selection.
@MainActor
final class SnippetPickerPopover: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var completion: ((Snippet?) -> Void)?

    /// Shows the picker. `completion` gets the chosen snippet, or nil when it was dismissed.
    func show(
        snippets: [Snippet], preferred: SnippetContext, relativeTo rect: NSRect, of view: NSView,
        completion: @escaping (Snippet?) -> Void
    ) {
        popover?.close()
        self.completion = completion
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: SnippetPickerView(
            snippets: SnippetPickerView.ordered(snippets, preferred: preferred)
        ) { [weak self] snippet in
            self?.finish(snippet)
        })
        self.popover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    private func finish(_ snippet: Snippet?) {
        let completion = self.completion
        self.completion = nil
        popover?.close()
        completion?(snippet)
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        if let completion {
            self.completion = nil
            completion(nil)
        }
    }
}

struct SnippetPickerView: View {
    let snippets: [Snippet]
    let choose: (Snippet?) -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var searching: Bool

    /// The preferred context's snippets first, then the others in their usual order.
    static func ordered(_ snippets: [Snippet], preferred: SnippetContext) -> [Snippet] {
        snippets.filter { $0.context == preferred } + snippets.filter { $0.context != preferred }
    }

    static func matching(_ snippets: [Snippet], query: String) -> [Snippet] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return snippets }
        return snippets.filter { snippet in
            let text = snippet.text.lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    private var shown: [Snippet] { Self.matching(snippets, query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Find a comment", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searching)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .onSubmit { chooseHighlighted() }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.escape) {
                    choose(nil)
                    return .handled
                }
                .onKeyPress(characters: .decimalDigits) { press in
                    // With nothing typed, a digit picks the comment with that number.
                    guard query.isEmpty, let digit = Int(press.characters), digit >= 1, digit <= min(9, shown.count) else { return .ignored }
                    choose(shown[digit - 1])
                    return .handled
                }
            Divider()

            if shown.isEmpty {
                Text(snippets.isEmpty ? "No comments saved yet. Add some in Settings." : "No saved comment matches.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, snippet in
                                if index == 0 || shown[index - 1].context != snippet.context {
                                    Text(snippet.context.title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.top, index == 0 ? 2 : 8)
                                        .padding(.bottom, 2)
                                }
                                row(snippet, index: index)
                                    .id(snippet.id)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 300)
                    .onChange(of: highlighted) { _, index in
                        if shown.indices.contains(index) { proxy.scrollTo(shown[index].id) }
                    }
                }
            }
        }
        .frame(width: 340)
        .onAppear { searching = true }
        .onChange(of: query) { highlighted = 0 }
    }

    private func row(_ snippet: Snippet, index: Int) -> some View {
        Button {
            choose(snippet)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snippet.text)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if query.isEmpty, index < 9 {
                    KeyCap("\(index + 1)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(index == highlighted ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlighted = index } }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !shown.isEmpty else { return .handled }
        highlighted = min(max(highlighted + step, 0), shown.count - 1)
        return .handled
    }

    private func chooseHighlighted() {
        guard shown.indices.contains(highlighted) else { return }
        choose(shown[highlighted])
    }
}
