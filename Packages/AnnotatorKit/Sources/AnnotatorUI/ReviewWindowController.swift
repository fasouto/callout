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
    private let window: NSWindow
    private var completion: ((ReviewResult) -> Void)?
    /// Each review has its own history of marks to undo.
    private let undoManager = UndoManager()

    /// - Parameter previousVersion: the previous plan of the same session, and
    ///   the number of this one, when the request is a revised plan.
    init(
        request: ReviewRequest, previousVersion: String? = nil, planVersion: Int? = nil,
        completion: @escaping (ReviewResult) -> Void
    ) {
        session = ReviewSession(request: request, previousVersion: previousVersion, planVersion: planVersion)
        self.completion = completion
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = session.title
        window.subtitle = Self.subtitle(for: request, planVersion: planVersion)
        // The title bar is part of the sheet of paper, not a strip above it.
        window.titlebarAppearsTransparent = true
        window.backgroundColor = session.isPDF ? .underPageBackgroundColor : .textBackgroundColor
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
            respond(ReviewResult(id: id, decision: .approve))
        case .applyEdits:
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
        window.close()
        completion(result)
    }

    /// Cancelling with marks on the page asks first; they cannot be brought back.
    private func confirmDiscard() -> Bool {
        guard session.hasFeedback else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard this review?"
        alert.informativeText = "Your marks and comments will be lost."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep Reviewing")
        return alert.runModal() == .alertFirstButtonReturn
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
