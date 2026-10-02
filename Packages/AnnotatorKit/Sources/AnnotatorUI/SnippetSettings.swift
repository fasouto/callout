import AnnotatorStore
import SwiftUI

/// The editor for reusable comments, one group per context.
struct SnippetSettings: View {
    let store: Store?
    @State private var snippets: [Snippet] = []
    @FocusState private var focused: Int64?

    var body: some View {
        Form {
            ForEach(SnippetContext.allCases) { context in
                Section(context.title) {
                    ForEach(snippets.filter { $0.context == context }) { snippet in
                        SnippetRow(snippet: snippet, focused: $focused) { text in
                            try? store?.updateSnippet(snippet.id, text: text)
                        } remove: {
                            try? store?.deleteSnippet(snippet.id)
                            reload()
                        }
                    }
                    Button {
                        if let added = try? store?.addSnippet("", context: context) {
                            reload()
                            focused = added.id
                        }
                    } label: {
                        Label("Add a comment", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Section {
            } footer: {
                Text("In a review, select text and press S to comment with one of these. The comments for what you are reviewing come first, and the first nine can be picked with their number.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .onDisappear(perform: removeEmpty)
    }

    private func reload() {
        snippets = (try? store?.snippets()) ?? []
    }

    /// A comment that was added and never written is not kept.
    private func removeEmpty() {
        for snippet in (try? store?.snippets()) ?? [] where snippet.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? store?.deleteSnippet(snippet.id)
        }
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    var focused: FocusState<Int64?>.Binding
    let save: (String) -> Void
    let remove: () -> Void

    @State private var text: String

    init(snippet: Snippet, focused: FocusState<Int64?>.Binding, save: @escaping (String) -> Void, remove: @escaping () -> Void) {
        self.snippet = snippet
        self.focused = focused
        self.save = save
        self.remove = remove
        _text = State(initialValue: snippet.text)
    }

    var body: some View {
        HStack {
            TextField("Comment", text: $text, axis: .vertical)
                .labelsHidden()
                .textFieldStyle(.plain)
                .focused(focused, equals: snippet.id)
                .onChange(of: text) { _, value in save(value) }
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove this comment")
            .accessibilityLabel("Remove this comment")
        }
    }
}
