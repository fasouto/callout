import CalloutCore
import SwiftUI

/// What the user decided to do with a review.
enum ReviewOutcome {
    case feedback
    case applyEdits
    case approve
    case cancel
}

/// The review window's content: the page with its margin, and the bar of actions under it.
/// For text captured from a terminal: the switch between the cleaned-up text
/// and the text as it was copied.
struct CaptureSwitch {
    var isShowingRaw: Bool
    var toggle: () -> Void
}

struct ReviewView: View {
    @Bindable var session: ReviewSession
    var capture: CaptureSwitch?
    let finish: (ReviewOutcome) -> Void

    var body: some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ActionBar(session: session, capture: capture, finish: finish)
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
        .overlayPreferenceValue(SelectedNoteKey.self) { note in
            GeometryReader { proxy in
                if let note, let mark = session.selectedMark, let start = margin.leaders[mark.id] {
                    Leader(start: start, end: proxy[note])
                        .stroke(mark.kind.symbolTint, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                }
            }
            .clipped()
            .allowsHitTesting(false)
        }
        .background(Color(nsColor: Theme.desk))
    }
}

/// The line across the desk from a mark, at the edge of the sheet, to its
/// note: out level with the mark, across, and in level with the note.
private struct Leader: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        Path { path in
            let run = min(10, max(0, end.x - start.x) / 3)
            path.move(to: start)
            path.addLine(to: CGPoint(x: start.x + run, y: start.y))
            path.addLine(to: CGPoint(x: end.x - run, y: end.y))
            path.addLine(to: end)
        }
    }
}

// MARK: - Actions

private struct ActionBar: View {
    @Bindable var session: ReviewSession
    var capture: CaptureSwitch?
    let finish: (ReviewOutcome) -> Void
    @FocusState private var writingOverall: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if session.isWelcome {
                    LessonStrip(session: session)
                        .padding(.bottom, 2)
                }
                overallComment
                HStack(spacing: 12) {
                    if session.isSelectingByKeyboard || session.isInserting {
                        Text(session.isInserting ? "Insert" : "Visual")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .help(!session.isInserting ? "Moving extends the selection. Press a mark key, or Esc to let go."
                                : "Keys add words to the document. Esc goes back to moving.")
                    }
                    if let message = session.statusMessage {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                    Spacer(minLength: 8)

                    if session.changes != nil {
                        Button(session.showsChanges ? "Hide Changes" : "Show Changes") { session.showsChanges.toggle() }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("What changed since the previous version of this plan: new text is tinted, removed text is struck in grey")
                    }
                    if let capture {
                        Button(capture.isShowingRaw ? "Show Cleaned Up" : "Show as Copied", action: capture.toggle)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help(capture.isShowingRaw
                                ? "Go back to the text with the terminal's frames and line breaks removed"
                                : "See the text exactly as it was copied from the terminal")
                    }
                    MarksOverview(session: session)

                    ResponseButtons(session: session, finish: finish)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
        }
        .background(.bar)
        .background {
            Button("Write the overall comment") { session.focusOverallComment() }
                .keyboardShortcut("o", modifiers: .command)
                .hidden()
        }
        .animation(.default, value: session.statusMessage)
        .onChange(of: session.overallFocusToken) { writingOverall = true }
    }

    /// What the reviewer says about the whole document: the note a teacher
    /// writes at the end of the essay. Always in view; it opens up while being
    /// written, and folds back to a few lines when the page has the keyboard.
    private var overallComment: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(writingOverall || !session.generalComment.isEmpty ? Color(nsColor: Theme.ink) : .secondary)
                .accessibilityHidden(true)
            TextField("Overall comment: what should change in general?", text: $session.generalComment, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(writingOverall ? 3...12 : 2...3)
                .focused($writingOverall)
                .onExitCommand { session.endEditing() }
                .accessibilityLabel("Overall comment")
            if !writingOverall, session.generalComment.isEmpty {
                KeyCap("⌘O")
                    .help("Press ⌘O to write here")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(writingOverall ? Color(nsColor: Theme.ink).opacity(0.7) : Color(nsColor: .separatorColor), lineWidth: writingOverall ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { writingOverall = true }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: writingOverall)
    }
}

/// The answers to the review: large, since they are what the window is for.
/// The one that applies right now carries the weight: Approve or Apply Edits
/// while nothing is marked, Send Feedback once something is. A review nobody
/// waits for says Copy instead of Send and Apply: that is what happens.
private struct ResponseButtons: View {
    let session: ReviewSession
    let finish: (ReviewOutcome) -> Void

    private var feedbackLeads: Bool {
        session.hasFeedback || !(session.allows.approve || session.allows.applyEdits)
    }

    /// AppKit can offer Esc to this button before the text that has the keyboard,
    /// where it finishes a note.
    private var escapeCancels: Bool {
        session.editing == nil && !Keymap.usesVimKeys
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { finish(.cancel) } label: {
                Text("Cancel").frame(minWidth: 64)
            }
            .keyboardShortcut(escapeCancels ? .cancelAction : nil)
            .buttonStyle(.bordered)
            .fixedSize()

            if session.allows.approve {
                response("Approve", leads: !feedbackLeads, minWidth: 92) { finish(.approve) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .help("Approve it as it is (⌘⇧↩)")
            } else if session.allows.applyEdits {
                response(session.editsAction, leads: !session.hasFeedback, minWidth: 104) { finish(.applyEdits) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(!session.hasEdits)
                    .help(session.answersToClipboard
                        ? "Copy the text with your edits applied, to paste anywhere (⌘⇧↩)"
                        : "Return the text with your edits applied (⌘⇧↩)")
            }
            if session.allows.feedback {
                response(session.feedbackAction, leads: feedbackLeads, minWidth: 128) { finish(.feedback) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!session.hasFeedback)
                    .help(!session.hasFeedback ? "Mark something or write an overall comment first"
                        : session.answersToClipboard ? "Copy your marks as feedback, to paste anywhere (⌘↩)"
                        : "Return your marks as feedback (⌘↩)")
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private func response(_ title: String, leads: Bool, minWidth: CGFloat, action: @escaping () -> Void) -> some View {
        let label = Text(title).fontWeight(leads ? .semibold : .regular).frame(minWidth: minWidth)
        // Always whole: the space before them gives way, never their words.
        if leads {
            Button(action: action) { label }.buttonStyle(.borderedProminent).fixedSize()
        } else {
            Button(action: action) { label }.buttonStyle(.bordered).fixedSize()
        }
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
        .accessibilityHidden(session.marks.isEmpty)
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

    /// Where a mark on no words is, in place of the words it does not have.
    private var place: String? {
        guard mark.anchor.isPoint, let place = mark.anchor.pointPlace else { return nil }
        return place.prefix(1).uppercased() + place.dropFirst()
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                if !quote.isEmpty {
                    Text(quote)
                        .lineLimit(1)
                        .strikethrough(mark.kind == .delete || mark.kind == .replace)
                        .foregroundStyle(mark.kind == .delete || mark.kind == .replace ? .secondary : .primary)
                } else if let place {
                    Text(place)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
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
        .markColourBar(mark.kind)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(mark.spokenDescription)
    }
}
