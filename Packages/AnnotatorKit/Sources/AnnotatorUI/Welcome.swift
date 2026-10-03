import AnnotatorCore
import AppKit
import SwiftUI

/// The first review: a short plan with the faults AI writing tends to have,
/// and a lesson that teaches the marks by making them. It is practice: it is
/// not kept in the history and nothing is sent anywhere.
enum Welcome {
    private static let shownKey = "welcomeShown"

    static var hasBeenShown: Bool {
        get { UserDefaults.standard.bool(forKey: shownKey) }
        set { UserDefaults.standard.set(newValue, forKey: shownKey) }
    }

    /// Named like a file, as reviewed documents are.
    static let title = "practice-plan.md"

    static let plan = """
    # Plan: make search faster

    We will leverage a very robust and comprehensive caching layer to dramatically improve performance across the board.

    The cache sits in front of the database and keeps every result forever, so search is always instant.

    Then we rewrite the importer, add monitoring, and ship on Friday.
    """

    static func request() -> ReviewRequest {
        ReviewRequest(
            content: .text(plan, format: .markdown), origin: .agentRequest,
            metadata: ReviewMetadata(title: title), reply: .stdout, modes: [.feedback]
        )
    }
}

/// One thing to learn in the first review, done by doing it.
struct LessonStep: Identifiable {
    let id: Int
    let title: String
    /// What to do, in Markdown: the words to select are in bold.
    let instruction: String
    let isDone: @MainActor (ReviewSession) -> Bool

    /// The words this step asks to select, which must be in the plan.
    var phrase: String? {
        instruction.components(separatedBy: "**").dropFirst().first
    }
}

enum Lesson {
    static let steps: [LessonStep] = [
        LessonStep(id: 0, title: "Strike the filler", instruction: "Select **very robust and comprehensive** and press D.") { session in
            session.marks.contains { $0.kind == .delete }
        },
        LessonStep(id: 1, title: "Use a plainer word", instruction: "Select **leverage**, press R and type *use*. Or just type over it.") { session in
            session.marks.contains { $0.kind == .replace && $0.text?.nilIfBlank != nil }
        },
        LessonStep(id: 2, title: "Question a claim", instruction: "Select **keeps every result forever**, press C and say what worries you.") { session in
            session.marks.contains { $0.kind == .comment }
        },
        LessonStep(id: 3, title: "Hand it in", instruction: "Press Send Feedback, or ⌘↩. Claude gets your marks as a list it can act on.") { _ in
            false
        },
    ]

    /// The first step not done yet.
    @MainActor static func current(in session: ReviewSession) -> Int {
        steps.firstIndex { !$0.isDone(session) } ?? steps.count - 1
    }
}

/// The lesson above the action bar: the steps in a row, and what to do now.
struct LessonStrip: View {
    let session: ReviewSession

    var body: some View {
        let current = Lesson.current(in: session)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Lesson.steps) { step in
                    if step.id > 0 {
                        Capsule()
                            .fill(step.id <= current ? Color(nsColor: Theme.ink).opacity(0.5) : Color.secondary.opacity(0.25))
                            .frame(width: 18, height: 2)
                    }
                    stepLabel(step, state: step.id < current ? .done : step.id == current ? .now : .later)
                }
            }
            Text(instruction(Lesson.steps[current]))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Now: \(Lesson.steps[current].title). \(Lesson.steps[current].instruction.replacingOccurrences(of: "*", with: ""))")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy(duration: 0.25), value: current)
    }

    private enum StepState { case done, now, later }

    private func stepLabel(_ step: LessonStep, state: StepState) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(state == .done ? Color(nsColor: Theme.keep) : state == .now ? Color(nsColor: Theme.ink) : Color.secondary.opacity(0.18))
                    .frame(width: 18, height: 18)
                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(step.id + 1)")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(state == .now ? .white : .secondary)
                }
            }
            Text(step.title)
                .font(.system(size: 12.5, weight: state == .now ? .semibold : .regular))
                .foregroundStyle(state == .later ? .secondary : .primary)
                // A step done is struck through, as on the page.
                .strikethrough(state == .done, color: Color(nsColor: Theme.pen).opacity(0.8))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(step.id + 1), \(step.title)\(state == .done ? ", done" : state == .now ? ", now" : "")")
    }

    private func instruction(_ step: LessonStep) -> AttributedString {
        (try? AttributedString(markdown: step.instruction)) ?? AttributedString(step.instruction)
    }
}

/// After the first review is handed in: what Claude would have received, and
/// the way on to marking up text from any app.
@MainActor
final class WelcomeFinish: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(feedback: String, setUpHotkey: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: WelcomeFinishView(
            feedback: feedback,
            setUpHotkey: { [weak self] in
                self?.window?.close()
                setUpHotkey()
            },
            close: { [weak self] in self?.window?.close() }
        ))
        if let content = window.contentView { window.setContentSize(content.fittingSize) }
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct WelcomeFinishView: View {
    let feedback: String
    let setUpHotkey: () -> Void
    let close: () -> Void

    private var isAllowed: Bool { SelectionCapture.isAllowed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Handed in")
                .font(.system(size: 24, weight: .bold, design: .serif))
                .padding(.bottom, 6)
            Text("This is what Claude receives. In Claude Code it goes back by itself: when you review a plan, or a reply with /annotate-last.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)

            ScrollView {
                Text(feedback)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            // As tall as the feedback, up to a point; longer feedback scrolls.
            .frame(height: min(320, CGFloat(feedback.split(separator: "\n", omittingEmptySubsequences: false).count) * 17 + 30))
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
            .padding(.bottom, 18)

            HStack {
                Text(isAllowed
                    ? "Next time, select text in any app and press \(Hotkey.stored.display)."
                    : "Next: mark up text from any app, with a shortcut.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if isAllowed {
                    Button("Done", action: close)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                } else {
                    Button("Later", action: close)
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)
                    Button("Set Up the Shortcut", action: setUpHotkey)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 22)
        .frame(width: 560, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
