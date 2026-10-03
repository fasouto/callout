import AnnotatorCore
import AnnotatorStore
import AppKit

/// Opens a window for each request and sends its result where the request asked.
@MainActor
final class ReviewCoordinator {
    private(set) var windows: [UUID: ReviewWindowController] = [:]
    /// False keeps windows off screen, for tests.
    private let presentsWindows: Bool
    /// Where plan versions are kept. Without it, plans are reviewed without a comparison.
    private let store: Store?

    init(presentsWindows: Bool = true, store: Store? = nil) {
        self.presentsWindows = presentsWindows
        self.store = store
    }

    /// - Parameter reply: receives the result, for requests that came from a
    ///   sender waiting for it. Copying to the clipboard is handled here.
    func open(_ request: ReviewRequest, reply: ((ReviewResult) -> Void)? = nil) {
        // A plan is remembered per session, so its next revision can show what changed.
        var previous: String?
        var version: Int?
        if request.origin == .planHook, let sessionId = request.metadata.sessionId,
           case .text(let plan, _) = request.content,
           let recorded = try? store?.recordPlan(plan, sessionId: sessionId) {
            previous = recorded.previous?.content
            version = recorded.version
        }
        let controller = ReviewWindowController(request: request, previousVersion: previous, planVersion: version) { [weak self] result in
            guard let self else { return }
            if let session = self.windows[request.id]?.session { self.remember(result, of: session) }
            self.windows[request.id] = nil
            self.deliver(result, for: request, reply: reply)
        }
        controller.loadSnippets = { [store] in (try? store?.snippets()) ?? [] }
        windows[request.id] = controller
        if presentsWindows { controller.show() }
    }

    /// Opens the first review. It is practice: the result goes to `completion`
    /// only, and is neither kept in the history nor copied.
    @discardableResult
    func openWelcome(completion: @escaping (ReviewResult) -> Void) -> UUID {
        let request = Welcome.request()
        let controller = ReviewWindowController(request: request, isWelcome: true) { [weak self] result in
            self?.windows[request.id] = nil
            completion(result)
        }
        controller.loadSnippets = { [store] in (try? store?.snippets()) ?? [] }
        windows[request.id] = controller
        if presentsWindows { controller.show() }
        return request.id
    }

    /// Keeps a finished review in the history. A cancelled one produced nothing to keep.
    private func remember(_ result: ReviewResult, of session: ReviewSession) {
        guard result.decision != .cancel else { return }
        try? store?.saveReview(
            session.request, result: result, marks: session.orderedSettledMarks,
            generalComment: session.generalComment.trimmingCharacters(in: .whitespacesAndNewlines),
            snippets: session.snippetUses
        )
    }

    private func deliver(_ result: ReviewResult, for request: ReviewRequest, reply: ((ReviewResult) -> Void)?) {
        if request.reply == .clipboard { copyToClipboard(result) }
        // A requester that is waiting always hears back, so it can stop waiting.
        reply?(result)
    }

    private func copyToClipboard(_ result: ReviewResult) {
        guard result.decision != .cancel else { return }
        let text: String
        let message: String
        if let edited = result.editedText {
            text = edited
            message = "Corrected text copied"
        } else if let feedback = result.feedback {
            text = feedback
            message = "Feedback copied"
        } else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Toast.show(message)
    }
}
