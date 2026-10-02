import AnnotatorCore
import AppKit

/// Opens a window for each request and sends its result where the request asked.
@MainActor
final class ReviewCoordinator {
    private(set) var windows: [UUID: ReviewWindowController] = [:]
    /// False keeps windows off screen, for tests.
    private let presentsWindows: Bool

    init(presentsWindows: Bool = true) {
        self.presentsWindows = presentsWindows
    }

    /// - Parameter reply: receives the result, for requests that came from a
    ///   sender waiting for it. Copying to the clipboard is handled here.
    func open(_ request: ReviewRequest, reply: ((ReviewResult) -> Void)? = nil) {
        let controller = ReviewWindowController(request: request) { [weak self] result in
            self?.windows[request.id] = nil
            self?.deliver(result, for: request, reply: reply)
        }
        windows[request.id] = controller
        if presentsWindows { controller.show() }
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
