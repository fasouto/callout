import AnnotatorCore
import SwiftUI

/// What the user decided to do with a review.
enum ReviewOutcome {
    case feedback
    case applyEdits
    case approve
    case cancel
}

/// The review window's content: the page with its margin, and the bar of actions under it.
struct ReviewView: View {
    @Bindable var session: ReviewSession
    let finish: (ReviewOutcome) -> Void

    var body: some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ActionBar(session: session, finish: finish)
            }
            .frame(minWidth: 720, minHeight: 440)
    }

    @ViewBuilder private var content: some View {
        if let failure = session.loadFailure {
            ContentUnavailableView("Nothing to review", systemImage: "doc.questionmark", description: Text(failure))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        } else if session.isPDF {
            PDFReview(session: session, finish: finish)
        } else {
            DocumentPane(
                session: session, revision: session.revision, focusToken: session.documentFocusToken
            ) { finish(.cancel) }
                .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

/// A PDF with its margin: the notes sit on the desk beside the sheet and follow it as it scrolls.
private struct PDFReview: View {
    let session: ReviewSession
    let finish: (ReviewOutcome) -> Void
    @State private var margin = MarginModel()

    var body: some View {
        HStack(spacing: 0) {
            PDFPane(
                session: session, margin: margin, revision: session.revision, focusToken: session.documentFocusToken
            ) { finish(.cancel) }
            MarginNotes(session: session, model: margin)
                .padding(.trailing, 16)
                .frame(width: Theme.marginWidth + 16)
                .clipped()
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

// MARK: - Actions

private struct ActionBar: View {
    @Bindable var session: ReviewSession
    let finish: (ReviewOutcome) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Overall comment", text: $session.generalComment, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .frame(maxWidth: 440)
                    .onExitCommand { session.endEditing() }
                    .accessibilityLabel("Overall comment")

                if let message = session.statusMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.bottom, 5)
                        .transition(.opacity)
                }
                Spacer(minLength: 8)

                MarksOverview(session: session)
                    .padding(.bottom, 1)

                Button("Cancel") { finish(.cancel) }
                    .keyboardShortcut(.cancelAction)
                if session.allows.approve {
                    Button("Approve") { finish(.approve) }
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                        .help("Approve it as it is (⌘⇧↩)")
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
                        .disabled(!session.hasFeedback)
                        .help(session.hasFeedback ? "Return your marks as feedback (⌘↩)" : "Mark something or write an overall comment first")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
        .animation(.default, value: session.statusMessage)
    }
}

/// How many marks there are, and a list to jump to any of them.
private struct MarksOverview: View {
    let session: ReviewSession
    @State private var isOpen = false

    private var title: String {
        let count = session.marks.count
        return count == 1 ? "1 mark" : "\(count) marks"
    }

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            Label(title, systemImage: "list.bullet")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(session.marks.isEmpty)
        .opacity(session.marks.isEmpty ? 0 : 1)
        .help("See every mark and jump to one")
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(session.orderedMarks) { mark in
                        Button {
                            session.selectedMarkID = mark.id
                            isOpen = false
                        } label: {
                            OverviewRow(mark: mark)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
            .frame(width: 320)
            .frame(maxHeight: 360)
        }
    }
}

private struct OverviewRow: View {
    let mark: Mark

    private var quote: String {
        let quote = mark.anchor.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        return quote.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: mark.kind.symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(mark.kind.tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                if !quote.isEmpty {
                    Text(quote)
                        .lineLimit(1)
                        .strikethrough(mark.kind == .delete || mark.kind == .replace)
                        .foregroundStyle(mark.kind == .delete || mark.kind == .replace ? .secondary : .primary)
                }
                if let text = mark.text?.nilIfBlank {
                    Text(text)
                        .italic()
                        .foregroundStyle(Color(nsColor: Theme.ink))
                        .lineLimit(1)
                }
                if let note = mark.note {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mark.kind.label): \(quote)")
    }
}
