import AnnotatorCore
import AppKit
import Testing
@testable import AnnotatorUI

@MainActor
@Suite("Opening the app")
struct OpeningTests {
    private final class Shown: NSWindow {
        override var isVisible: Bool { true }
    }

    private final class Minimized: NSWindow {
        override var isMiniaturized: Bool { true }
    }

    private func window<Window: NSWindow>(_ type: Window.Type, _ style: NSWindow.StyleMask) -> Window {
        let window = Window(contentRect: .zero, styleMask: style, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func onlyAPersonOpeningTheAppGetsAWindow() {
        // From Finder, Spotlight or Launchpad.
        #expect(Opening.isByHand(arguments: ["Annotator"], isDefaultLaunch: true, atLogin: false))
        // The command-line tool starting it for the review that follows.
        #expect(!Opening.isByHand(arguments: ["Annotator", "--background"], isDefaultLaunch: true, atLogin: false))
        #expect(!Opening.isByHand(arguments: ["Annotator", "--review", "plan.md"], isDefaultLaunch: true, atLogin: false))
        // At login it only takes its place in the menu bar.
        #expect(!Opening.isByHand(arguments: ["Annotator"], isDefaultLaunch: true, atLogin: true))
        // Launched to open a file, a link from the Share menu or a Services request.
        #expect(!Opening.isByHand(arguments: ["Annotator"], isDefaultLaunch: false, atLogin: false))
    }

    @Test func openingItAgainBringsBackAWindowItHas() {
        _ = NSApplication.shared
        let menuBarIcon = window(Shown.self, [.borderless])
        #expect(!Opening.hasWindow([menuBarIcon]))
        #expect(Opening.hasWindow([menuBarIcon, window(Shown.self, [.titled])]))
        #expect(Opening.hasWindow([window(Minimized.self, [.titled, .miniaturizable])]))
        // A window that was closed is not one to bring back.
        #expect(!Opening.hasWindow([window(NSWindow.self, [.titled])]))
    }

    @Test func aReviewFromAnotherAppComesForwardAlone() {
        _ = NSApplication.shared
        let review = ReviewWindowController(request: ReviewRequest(
            content: .text("A reply.", format: .markdown), origin: .lastReply, reply: .stdout, modes: [.feedback]
        )) { _ in }
        let otherReview = ReviewWindowController(request: ReviewRequest(
            content: .text("A plan.", format: .markdown), origin: .planHook, reply: .hookDecision, modes: [.feedback]
        )) { _ in }
        let history = window(Shown.self, [.titled, .closable])
        let menuBarIcon = window(Shown.self, [.borderless])
        let closedSettings = window(NSWindow.self, [.titled])
        // Another review, on screen: work in progress, which stays.
        let reviewOnScreen = window(Shown.self, [.titled, .closable])
        reviewOnScreen.delegate = otherReview
        let open = [history, menuBarIcon, closedSettings, reviewOnScreen, review.window]

        // Sent from Claude Code while the person was in another app: the history
        // left open from earlier goes, so it is not what is left once the review is sent.
        let away = Opening.windowsToPutAway(open, forReviewIn: review.window, appIsActive: false)
        #expect(away.count == 1)
        #expect(away.first === history)
        // Opened from inside Annotator: everything stays where it is.
        #expect(Opening.windowsToPutAway(open, forReviewIn: review.window, appIsActive: true).isEmpty)
    }

    /// Reviews are open side by side, each in its own window, and each answer
    /// goes back to the one that asked for it.
    @Test func severalReviewsAreOpenAtOnceAndAnsweredApart() throws {
        _ = NSApplication.shared
        let coordinator = ReviewCoordinator(presentsWindows: false)
        func request(_ title: String) -> ReviewRequest {
            ReviewRequest(
                content: .text("We will leverage a very robust approach here.", format: .markdown), origin: .lastReply,
                metadata: ReviewMetadata(title: title), reply: .stdout, modes: [.feedback]
            )
        }
        let plan = request("Plan")
        let reply = request("Reply")
        var answers: [String: ReviewDecision] = [:]
        coordinator.open(plan) { answers["Plan"] = $0.decision }
        coordinator.open(reply) { answers["Reply"] = $0.decision }
        #expect(coordinator.windows.count == 2)

        let replyWindow = try #require(coordinator.windows[reply.id])
        replyWindow.session.addMark(.delete, span: TextSpan(19, 31))
        replyWindow.finish(.feedback)
        #expect(answers == ["Reply": .feedback])
        #expect(coordinator.windows.keys.map { $0 } == [plan.id])

        coordinator.windows[plan.id]?.finish(.cancel)
        #expect(answers == ["Reply": .feedback, "Plan": .cancel])
        #expect(coordinator.windows.isEmpty)
    }
}
