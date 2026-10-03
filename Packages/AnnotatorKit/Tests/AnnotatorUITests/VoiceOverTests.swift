import AnnotatorCore
import AppKit
import SwiftUI
import Testing
@testable import AnnotatorUI

@MainActor
@Suite("VoiceOver")
struct VoiceOverTests {
    private static let source = "We will leverage a very robust approach here.\n\nShip it on Friday."

    private func session() -> ReviewSession {
        ReviewSession(request: ReviewRequest(
            content: .text(Self.source, format: .markdown), origin: .lastReply,
            metadata: ReviewMetadata(title: "Reply"), reply: .clipboard, modes: [.feedback, .applyEdits]
        ))
    }

    private func span(_ phrase: String) -> TextSpan {
        let range = (Self.source as NSString).range(of: phrase)
        return TextSpan(range.location, NSMaxRange(range))
    }

    @Test func eachMarkSaysWhatWasDoneToWhichWords() throws {
        let session = session()
        session.announce = { _ in }
        let said = { (mark: Mark?) in mark?.spokenDescription }
        #expect(said(session.addMark(.delete, span: span("very robust"))) == "Struck out: very robust")
        #expect(said(session.addMark(.replace, span: span("leverage"), text: "use")) == "Replaced: leverage, with: use")
        #expect(said(session.addMark(.keep, span: span("approach"))) == "Keep as is: approach")
        #expect(said(session.addMark(.comment, span: span("Friday"), note: "Too soon?")) == "Comment on Friday: Too soon?")
        #expect(said(session.addMark(.summarize, span: span("We will"))) == "Asked to shorten: We will")
        let end = span("Ship it").end
        #expect(said(session.addMark(.insert, span: TextSpan(end, end), text: "carefully")) == "Added after Ship it: carefully")
    }

    @Test func makingAndRemovingAMarkIsAnnounced() throws {
        let session = session()
        var heard: [String] = []
        session.announce = { heard.append($0) }
        let mark = try #require(session.addMark(.delete, span: span("very robust")))
        session.remove(mark.id)
        #expect(heard == ["Struck out: very robust", "Removed. Struck out: very robust"])
    }

    @Test func theRotorGoesFromMarkToMarkInOrder() throws {
        _ = NSApplication.shared
        let session = session()
        session.announce = { _ in }
        session.addMark(.keep, span: span("Friday"))
        session.addMark(.delete, span: span("very robust"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ReviewView(session: session) { _ in })
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        func find(_ view: NSView?) -> AnnotationTextView? {
            guard let view else { return nil }
            if let match = view as? AnnotationTextView { return match }
            return view.subviews.lazy.compactMap(find).first
        }
        let textView = try #require(find(window.contentView))
        let rotor = try #require(textView.accessibilityCustomRotors().first)
        #expect(rotor.label == "Marks")
        let delegate = try #require(rotor.itemSearchDelegate)

        let parameters = NSAccessibilityCustomRotor.SearchParameters()
        parameters.searchDirection = .next
        let first = try #require(delegate.rotor(rotor, resultFor: parameters))
        #expect(first.customLabel == "Struck out: very robust")
        #expect((textView.string as NSString).substring(with: first.targetRange) == "very robust")

        parameters.currentItem = first
        let second = try #require(delegate.rotor(rotor, resultFor: parameters))
        #expect(second.customLabel == "Keep as is: Friday")
        parameters.currentItem = second
        #expect(delegate.rotor(rotor, resultFor: parameters) == nil)

        parameters.searchDirection = .previous
        #expect(delegate.rotor(rotor, resultFor: parameters)?.customLabel == "Struck out: very robust")
    }
}
