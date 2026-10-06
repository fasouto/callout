import AnnotatorCore
import AnnotatorStore
import AppKit
import SwiftUI

/// One review window. Calls `completion` exactly once, when the user responds
/// or closes the window.
@MainActor
final class ReviewWindowController: NSObject, NSWindowDelegate {
    private(set) var session: ReviewSession
    /// Where the reusable comments come from. Applies to the session shown now and to any shown later.
    var loadSnippets: () -> [Snippet] = { [] } {
        didSet { session.loadSnippets = loadSnippets }
    }
    /// For a capture that was cleaned up: whether the text as it was copied is showing instead.
    private(set) var isShowingRawCapture = false
    let window: NSWindow
    private var completion: ((ReviewResult) -> Void)?
    /// Each review has its own history of marks to undo.
    private let undoManager = UndoManager()

    /// - Parameter previousVersion: the previous plan of the same session, and
    ///   the number of this one, when the request is a revised plan.
    init(
        request: ReviewRequest, previousVersion: String? = nil, planVersion: Int? = nil, isWelcome: Bool = false,
        completion: @escaping (ReviewResult) -> Void
    ) {
        session = ReviewSession(request: request, previousVersion: previousVersion, planVersion: planVersion, isWelcome: isWelcome)
        self.completion = completion
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = session.title
        window.subtitle = isWelcome ? "Practice: nothing is sent" : Self.subtitle(for: request, planVersion: planVersion)
        // The title bar is part of the sheet of paper, not a strip above it.
        window.titlebarAppearsTransparent = true
        // The same desk as around the PDF's pages, so the title bar is not a strip of another grey.
        window.backgroundColor = session.isPDF ? Theme.desk : .textBackgroundColor
        window.isReleasedWhenClosed = false
        window.delegate = self
        showSession()
        window.setFrameAutosaveName("ReviewWindow")
        if window.frame.origin == .zero { window.center() }
    }

    private func showSession() {
        var capture: CaptureSwitch?
        if session.request.metadata.rawCapture != nil {
            capture = CaptureSwitch(isShowingRaw: isShowingRawCapture) { [weak self] in self?.switchCapture() }
        }
        window.contentView = NSHostingView(rootView: ReviewView(session: session, capture: capture) { [weak self] outcome in
            self?.finish(outcome)
        })
        undoManager.removeAllActions()
        session.undoManager = undoManager
        session.loadSnippets = loadSnippets
    }

    /// Swaps between the cleaned-up text and the text as it was copied. Marks
    /// belong to one text, so they do not survive the swap.
    func switchCapture() {
        guard let raw = session.request.metadata.rawCapture else { return }
        if session.hasFeedback {
            let alert = NSAlert()
            alert.messageText = isShowingRawCapture ? "Show the cleaned-up text?" : "Show the text as it was copied?"
            alert.informativeText = "Your marks were made on this version and will be lost."
            alert.addButton(withTitle: "Switch")
            alert.addButton(withTitle: "Keep Reviewing")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var request = session.request
        if isShowingRawCapture {
            request.content = .text(TerminalCleanup.clean(raw), format: .markdown)
        } else {
            request.content = .text(raw, format: .plain)
        }
        isShowingRawCapture.toggle()
        session = ReviewSession(request: request)
        showSession()
    }

    func show() {
        // A menu-bar app is not active when a request arrives.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func subtitle(for request: ReviewRequest, planVersion: Int?) -> String {
        switch request.origin {
        case .planHook: (planVersion ?? 1) > 1 ? "Plan, version \(planVersion ?? 1)" : "Plan"
        case .lastReply: "Reply"
        case .agentRequest: "Document"
        case .hotkey, .service: "Selection"
        case .fileDrop, .share: "File"
        }
    }

    // MARK: - Finishing

    func finish(_ outcome: ReviewOutcome) {
        let id = session.request.id
        // A note still being written counts, and an empty one is dropped.
        if outcome != .cancel, session.editing != nil { session.endEditing() }
        switch outcome {
        case .feedback:
            respond(ReviewResult(id: id, decision: .feedback, feedback: session.feedback()))
        case .approve:
            // Approving sends nothing but the approval: marks would be lost without a word.
            if session.hasFeedback {
                switch ask(
                    "Approve without your feedback?",
                    "Approving tells Claude to go ahead as it is. \(markCount) and your overall comment are not sent.",
                    buttons: ["Send Feedback", "Approve Anyway", "Keep Reviewing"]
                ) {
                case .alertFirstButtonReturn: return finish(.feedback)
                case .alertSecondButtonReturn: break
                default: return
                }
            }
            respond(ReviewResult(id: id, decision: .approve))
        case .applyEdits:
            // The corrected text carries edits only; comments and the like have nowhere to go.
            let notEdits = session.marks.filter { !$0.kind.isEdit }.count
            let general = session.generalComment.nilIfBlank != nil
            if notEdits > 0 || general {
                let what = [notEdits > 0 ? "Comments and other notes on the text" : nil, general ? "the overall comment" : nil]
                    .compactMap { $0 }.joined(separator: " and ")
                guard ask(
                    "Apply only the edits?",
                    "The corrected text includes your deletions, replacements and additions. \(what) are not part of it.",
                    buttons: ["Apply Edits", "Keep Reviewing"]
                ) == .alertFirstButtonReturn else { return }
            }
            do {
                respond(ReviewResult(id: id, decision: .feedback, editedText: try session.editedText()))
            } catch {
                session.statusMessage = "The edits could not be applied."
                NSSound.beep()
            }
        case .cancel:
            guard confirmDiscard() else { return }
            respond(ReviewResult(id: id, decision: .cancel))
        }
    }

    private func respond(_ result: ReviewResult) {
        guard let completion else { return }
        self.completion = nil
        // The answer goes out at once; the window takes a moment to leave.
        completion(result)
        handIn(result.decision)
    }

    /// The review is handed in: the sheet lifts off the desk and goes, an
    /// approval stamped first. A cancelled review just closes, and so does
    /// everything when motion is reduced.
    private func handIn(_ decision: ReviewDecision) {
        guard window.isVisible, decision != .cancel, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.close()
            return
        }
        if decision == .approve, let content = window.contentView {
            let stamp = NSHostingView(rootView: ApprovalStamp())
            stamp.frame = content.bounds
            stamp.autoresizingMask = [.width, .height]
            content.addSubview(stamp)
        }
        let window = window
        DispatchQueue.main.asyncAfter(deadline: .now() + (decision == .approve ? 0.5 : 0.05)) {
            var frame = window.frame
            frame.origin.y += 28
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
                window.animator().setFrame(frame, display: true)
            }, completionHandler: {
                // AppKit calls this on the main thread.
                MainActor.assumeIsolated {
                    window.close()
                    window.alphaValue = 1
                }
            })
        }
    }

    /// Cancelling with marks on the page asks first; they cannot be brought back.
    private func confirmDiscard() -> Bool {
        guard session.hasFeedback else { return true }
        return ask("Discard this review?", "Your marks and comments will be lost.", buttons: ["Discard", "Keep Reviewing"])
            == .alertFirstButtonReturn
    }

    private var markCount: String {
        let count = session.marks.count
        return count == 0 ? "Nothing you marked" : count == 1 ? "Your mark" : "Your \(count) marks"
    }

    /// Asks a question in an alert. Tests answer it themselves.
    var ask: (_ message: String, _ detail: String, _ buttons: [String]) -> NSApplication.ModalResponse = { message, detail, buttons in
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        for title in buttons { alert.addButton(withTitle: title) }
        return alert.runModal()
    }

    private func ask(_ message: String, _ detail: String, buttons: [String]) -> NSApplication.ModalResponse {
        ask(message, detail, buttons)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        undoManager
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard completion != nil else { return true }
        finish(.cancel)
        return false
    }
}

/// Pressed onto the page when a plan is approved, just before it goes.
struct ApprovalStamp: View {
    @State private var landed = false

    var body: some View {
        Text("Approved")
            .font(.system(size: 34, weight: .heavy, design: .rounded))
            .foregroundStyle(Color(nsColor: Theme.keep))
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: Theme.keep), lineWidth: 4))
            .rotationEffect(.degrees(-8))
            .scaleEffect(landed ? 1 : 1.6)
            .opacity(landed ? 0.92 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityLabel("Approved")
            .onAppear {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.6)) { landed = true }
            }
    }
}
