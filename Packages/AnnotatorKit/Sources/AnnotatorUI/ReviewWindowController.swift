import AnnotatorCore
import AppKit
import SwiftUI

/// One review window. Calls `completion` exactly once, when the user responds
/// or closes the window.
@MainActor
final class ReviewWindowController: NSObject, NSWindowDelegate {
    let session: ReviewSession
    private let window: NSWindow
    private var completion: ((ReviewResult) -> Void)?
    /// Each review has its own history of marks to undo.
    private let undoManager = UndoManager()

    init(request: ReviewRequest, completion: @escaping (ReviewResult) -> Void) {
        session = ReviewSession(request: request)
        self.completion = completion
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = session.title
        window.subtitle = Self.subtitle(for: request)
        // The title bar is part of the sheet of paper, not a strip above it.
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .textBackgroundColor
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ReviewView(session: session) { [weak self] outcome in
            self?.finish(outcome)
        })
        session.undoManager = undoManager
        window.setFrameAutosaveName("ReviewWindow")
        if window.frame.origin == .zero { window.center() }
    }

    func show() {
        // A menu-bar app is not active when a request arrives.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func subtitle(for request: ReviewRequest) -> String {
        switch request.origin {
        case .planHook: "Plan"
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
