import AnnotatorCore
import SwiftUI

/// What the user decided to do with a review.
enum ReviewOutcome {
    case feedback
    case applyEdits
    case approve
    case cancel
}

/// The review window's content: the document, the list of marks and the actions.
struct ReviewView: View {
    @Bindable var session: ReviewSession
    let finish: (ReviewOutcome) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                TextPane(session: session, revision: session.revision) { finish(.cancel) }
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                SidePanel(session: session)
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 420, maxHeight: .infinity)
            }
            Divider()
            ActionBar(session: session, finish: finish)
        }
        .frame(minWidth: 760, minHeight: 460)
    }
}

// MARK: - Side panel

private struct SidePanel: View {
    @Bindable var session: ReviewSession

    var body: some View {
        VStack(spacing: 0) {
            if session.marks.isEmpty {
                EmptyMarks()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $session.selectedMarkID) {
                    ForEach(session.orderedMarks) { mark in
                        MarkRow(mark: mark).tag(mark.id)
                    }
                }
                .listStyle(.sidebar)
                .onDeleteCommand {
                    if let id = session.selectedMarkID { session.remove(id) }
                }
            }

            if let mark = session.selectedMark {
                Divider()
                MarkDetail(session: session, mark: mark)
                    .id(mark.id)
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("General comment")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("About the whole document", text: $session.generalComment, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...8)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(12)
        }
    }
}

private struct EmptyMarks: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No marks yet")
                .font(.headline)
            Text("Select text, then press a key.")
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                ForEach(MarkKind.allCases, id: \.self) { kind in
                    GridRow {
                        KeyCap(kind.key)
                        Label(kind.label, systemImage: kind.symbol)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(20)
    }
}

private struct KeyCap: View {
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .frame(minWidth: 18)
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct MarkRow: View {
    let mark: Mark

    private var quote: String {
        let quote = mark.anchor.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        return quote.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: mark.kind.symbol)
                .foregroundStyle(mark.kind.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                if !quote.isEmpty {
                    Text(quote)
                        .lineLimit(2)
                        .strikethrough(mark.kind == .delete || mark.kind == .replace)
                        .foregroundStyle(mark.kind == .delete || mark.kind == .replace ? .secondary : .primary)
                }
                if let text = mark.text, !text.isEmpty {
                    Text(text).lineLimit(2)
                }
                if let note = mark.note {
                    Text(note)
                        .lineLimit(2)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mark.kind.label): \(quote)")
    }
}

/// Edits the text and the note of the selected mark.
private struct MarkDetail: View {
    let session: ReviewSession
    let mark: Mark

    @State private var text: String
    @State private var note: String

    init(session: ReviewSession, mark: Mark) {
        self.session = session
        self.mark = mark
        _text = State(initialValue: mark.text ?? "")
        _note = State(initialValue: mark.note ?? "")
    }

    private var noteLabel: String {
        mark.kind == .comment ? "Comment" : "Reason (optional)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(mark.kind.label, systemImage: mark.kind.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    session.remove(mark.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this mark (⌫)")
                .accessibilityLabel("Remove this mark")
            }
            if mark.kind == .replace || mark.kind == .insert {
                field(mark.kind == .replace ? "Replace with" : "Text to insert", text: $text)
                    .onChange(of: text) { _, value in session.update(mark.id, text: value) }
            }
            if mark.kind != .keep {
                field(noteLabel, text: $note)
                    .onChange(of: note) { _, value in session.update(mark.id, note: value) }
            }
        }
        .padding(12)
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...6)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

extension MarkKind {
    var tint: Color {
        switch self {
        case .delete: .red
        case .replace: .orange
        case .insert: .green
        case .comment: .yellow
        case .keep: .green
        }
    }
}

// MARK: - Actions

private struct ActionBar: View {
    let session: ReviewSession
    let finish: (ReviewOutcome) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("Cancel") { finish(.cancel) }
                .keyboardShortcut(.cancelAction)

            if let message = session.statusMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()

            if session.allows.approve {
                Button("Approve") { finish(.approve) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .help("Approve as it is (⌘⇧↩)")
            } else if session.allows.applyEdits {
                Button("Apply Edits") { finish(.applyEdits) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(!session.hasEdits)
                    .help("Return the text with your edits applied (⌘⇧↩)")
            }
            if session.allows.feedback {
                Button("Send Feedback") { finish(.feedback) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .help("Return your marks as feedback (⌘↩)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
