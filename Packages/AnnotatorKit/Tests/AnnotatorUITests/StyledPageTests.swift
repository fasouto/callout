import AnnotatorCore
import AppKit
import SwiftUI
import Testing
@testable import AnnotatorUI

extension OnTheMainThread {
    /// The page is changed in place, part by part. Whatever was done, it must be
    /// exactly the page that would be made from scratch.
    @MainActor
    @Suite("Page kept up to date")
    struct StyledPageTests {
        private static let source = """
        # Plan: add rate limiting

        The API has **no limits** today, so a single client can exhaust the pool.
        See [the incident report](https://example.com/incidents/42) for details.

        1. Add a `RateLimiter` middleware
           - token bucket, *per API key*
        2. Return `429` with a `Retry-After` header

        ```python
        class RateLimiter:
            def allow(self, key: str) -> bool:
                return self.bucket(key).take()
        ```

        | Setting | Default | Notes |
        |---|---|---|
        | `RATE_LIMIT_RPS` | 10 | Requests per second for each API key |
        | `RATE_LIMIT_BURST` | 20 | Bucket size |

        | Round | What changed | Requests refused | Clients affected | Agreement with the old limits |
        |---|---|---|---|---|
        | 1 | first bucket | 488 | 93 | 84% |
        | 2 | burst and retry fixes | 914 | 34 | 96.5% |

        > Note: this does not cover websockets.
        > Nor does it cover the admin API.

        We will leverage a very robust approach here, and it's quick -- really.
        """

        /// A generator that gives the same steps on every run.
        private struct Steps: RandomNumberGenerator {
            var state: UInt64
            mutating func next() -> UInt64 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return state
            }
        }

        /// The page as the text view would hold it after `refresh`.
        @MainActor
        private final class Shown {
            let storage = NSTextStorage()
            var page: StyledPage?
            var edited = 0
            var remade = 0

            func refresh(_ session: ReviewSession) {
                let added = session.shownChanges?.added ?? []
                if let edits = page?.update(to: session.layout, marks: session.marks, selectedMarkID: session.selectedMarkID, added: added) {
                    for edit in edits { storage.replaceCharacters(in: edit.range, with: edit.text) }
                    edited += 1
                } else {
                    let made = StyledPage(layout: session.layout, marks: session.marks, selectedMarkID: session.selectedMarkID, added: added)
                    page = made
                    storage.setAttributedString(made.text)
                    remade += 1
                }
            }
        }

        private func expectSameAsMadeAgain(_ shown: Shown, _ session: ReviewSession, _ step: String) {
            // Text storage gives each paragraph the style of its first character, as
            // the text view lays it out: compare with a page set the same way.
            let fresh = NSTextStorage()
            fresh.setAttributedString(TextStyler.attributedString(
                layout: session.layout, marks: session.marks, selectedMarkID: session.selectedMarkID,
                added: session.shownChanges?.added ?? []
            ))
            guard !shown.storage.isEqual(to: fresh) else { return }
            // Name the first place they differ.
            let a = shown.storage, b = fresh
            var at = 0
            while at < min(a.length, b.length),
                  (a.string as NSString).character(at: at) == (b.string as NSString).character(at: at),
                  NSDictionary(dictionary: a.attributes(at: at, effectiveRange: nil)).isEqual(to: b.attributes(at: at, effectiveRange: nil)) {
                at += 1
            }
            let context = (b.string as NSString).substring(with: NSRange(location: max(0, at - 20), length: min(40, b.length - max(0, at - 20))))
            var keys = ""
            if at < min(a.length, b.length) {
                let x = a.attributes(at: at, effectiveRange: nil), y = b.attributes(at: at, effectiveRange: nil)
                for key in Set(x.keys).union(y.keys) where !(x[key].map { NSDictionary(dictionary: [key: $0]) }?.isEqual(to: y[key].map { [key: $0] } ?? [:]) ?? false) {
                    keys += " \(key.rawValue): \(String(describing: x[key]).prefix(120)) vs \(String(describing: y[key]).prefix(120));"
                }
            }
            Issue.record("after \(step): pages differ at \(at) of \(a.length)/\(b.length), near \(context.debugDescription):\(keys)")
        }

        private func words(in session: ReviewSession) -> [Range<Int>] {
            let text = session.layout.text as NSString
            var found: [Range<Int>] = []
            text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byWords) { _, range, _, _ in
                if let span = Range(range) { found.append(span) }
            }
            return found
        }

        /// The plan as it was before, so that a revision also shows removed lines among the marks.
        private static let previousVersion = """
        # Plan: add rate limiting

        The API has limits today.

        1. Add a `RateLimiter` middleware
           - a fixed window per IP
        2. Log every rejected request
        3. Return `429` with a `Retry-After` header

        > Note: this does not cover websockets.

        We will leverage a very robust approach here, and it's quick -- really.
        """

        /// Four by default; `PAGE_SEEDS=100 swift test --filter StyledPageTests` for a long run.
        nonisolated private static var seeds: [(UInt64, Bool)] {
            let count = UInt64(ProcessInfo.processInfo.environment["PAGE_SEEDS"].flatMap(Int.init) ?? 4)
            return (1...count).flatMap { [($0, false), ($0, true)] }
        }

        @Test(arguments: seeds)
        func randomChangesLeaveTheSamePageAsMakingItAgain(seed: UInt64, isRevision: Bool) throws {
            _ = NSApplication.shared
            let session = ReviewSession(
                request: ReviewRequest(
                    content: .text(Self.source, format: .markdown), origin: isRevision ? .planHook : .agentRequest,
                    reply: .stdout, modes: [.feedback, .applyEdits]
                ),
                previousVersion: isRevision ? Self.previousVersion : nil
            )
            session.announce = { _ in }
            let undo = UndoManager()
            undo.groupsByEvent = false
            session.undoManager = undo
            var random = Steps(state: seed)
            let shown = Shown()
            shown.refresh(session)

            for step in 0..<150 {
                let viewWords = words(in: session)
                let word = viewWords.randomElement(using: &random) ?? 0..<1
                let wide = word.lowerBound..<(viewWords.randomElement(using: &random).map { max($0.upperBound, word.upperBound) } ?? word.upperBound)
                let choice = Int.random(in: 0..<14, using: &random)
                var name = "step \(step)"
                switch choice {
                case 1:
                    let text = session.layout.text as NSString
                    let paragraph = text.paragraphRange(for: NSRange(location: min(word.lowerBound, text.length), length: 0))
                    let paragraphEnd = NSMaxRange(paragraph) - (text.substring(with: paragraph).hasSuffix("\n") ? 1 : 0)
                    let point = [word.lowerBound, word.upperBound, paragraph.location, paragraphEnd, text.length].randomElement(using: &random)!
                    name += ": comment pinned at \(point)"
                    session.addMark(.comment, anchor: session.pointAnchor(atView: point), note: "here?")
                case 0:
                    let kind = [MarkKind.delete, .keep, .comment, .expand, .summarize].randomElement(using: &random)!
                    name += ": \(kind) on \(word)"
                    if let span = session.sourceSpan(forView: Bool.random(using: &random) ? word : wide) { session.addMark(kind, span: span) }
                case 2:
                    name += ": replace \(word) and type"
                    if let span = session.sourceSpan(forView: word), let placed = session.replaceInPlace(span: span) {
                        var caret = placed.caret
                        for letter in ["n", "e", "w", " ", "w"] { caret = session.type(letter, atView: caret) ?? caret }
                    }
                case 3:
                    name += ": type at \(word.lowerBound)"
                    var caret = word.lowerBound
                    for letter in ["a", "d", "d", "\n", "x"] { caret = session.type(letter, atView: caret) ?? caret }
                case 4:
                    name += ": delete characters at \(word.upperBound)"
                    var caret = word.upperBound
                    for _ in 0..<3 { caret = session.deleteCharacter(atView: caret, forward: Bool.random(using: &random)) ?? caret }
                case 5:
                    name += ": write a note"
                    if let mark = session.marks.randomElement(using: &random) { session.update(mark.id, note: "note \(step)") }
                case 6:
                    name += ": change a replacement's text"
                    if let mark = session.marks.filter({ $0.kind == .replace || $0.kind == .insert }).randomElement(using: &random) {
                        session.update(mark.id, text: (mark.text ?? "") + "z")
                    }
                case 7:
                    name += ": remove a mark"
                    if let mark = session.marks.randomElement(using: &random) { session.remove(mark.id) }
                case 8, 9:
                    name += ": select another mark"
                    session.selectedMarkID = Bool.random(using: &random) ? session.marks.randomElement(using: &random)?.id : nil
                case 10:
                    name += ": next mark"
                    session.selectMark(offsetBy: Bool.random(using: &random) ? 1 : -1)
                case 11:
                    name += ": undo"
                    if undo.canUndo { undo.undo() }
                case 12:
                    name += ": redo"
                    if undo.canRedo { undo.redo() }
                default:
                    name += ": comment with a note on \(wide)"
                    if let span = session.sourceSpan(forView: wide) { session.addMark(.comment, span: span, note: "why?") }
                }
                shown.refresh(session)
                expectSameAsMadeAgain(shown, session, name)
            }
            // The point of it: most changes were made in place.
            #expect(shown.edited > 100, "edited \(shown.edited), remade \(shown.remade)")
        }

        @Test func aNoteChangesNothingOnThePage() throws {
            _ = NSApplication.shared
            let session = ReviewSession(request: ReviewRequest(
                content: .text(Self.source, format: .markdown), origin: .agentRequest, reply: .stdout, modes: [.feedback]
            ))
            session.announce = { _ in }
            let range = (session.layout.text as NSString).range(of: "robust")
            let span = try #require(session.sourceSpan(forView: range.location..<NSMaxRange(range)))
            let mark = try #require(session.addMark(.comment, span: span))
            let page = StyledPage(layout: session.layout, marks: session.marks, selectedMarkID: session.selectedMarkID, added: [])
            session.update(mark.id, note: "Which part?")
            #expect(page.update(to: session.layout, marks: session.marks, selectedMarkID: session.selectedMarkID, added: [])?.isEmpty == true)
        }

        @Test func showingWhatChangedInAPlanMakesThePageAgain() throws {
            _ = NSApplication.shared
            let session = ReviewSession(
                request: ReviewRequest(content: .text("# Plan\n\nKeep this.\n\nNew step.", format: .markdown), origin: .planHook, reply: .hookDecision, modes: [.feedback]),
                previousVersion: "# Plan\n\nKeep this.\n\nOld step."
            )
            session.announce = { _ in }
            let shown = Shown()
            shown.refresh(session)
            session.showsChanges.toggle()
            shown.refresh(session)
            expectSameAsMadeAgain(shown, session, "hiding the changes")
            session.showsChanges.toggle()
            shown.refresh(session)
            expectSameAsMadeAgain(shown, session, "showing them again")
            #expect(shown.remade == 3)
        }
    }
}

extension OnTheMainThread {
    /// The same, through a real review window: what the text view holds after each
    /// change is what a page made from scratch would hold.
    @MainActor
    @Suite("Page kept up to date, in a window")
    struct StyledPageWindowTests {
        private func findTextView(in view: NSView?) -> AnnotationTextView? {
            guard let view else { return nil }
            if let textView = view as? AnnotationTextView { return textView }
            for subview in view.subviews {
                if let found = findTextView(in: subview) { return found }
            }
            return nil
        }

        @Test func theTextViewHoldsWhatAFreshPageWould() throws {
            _ = NSApplication.shared
            let source = "# Plan\n\nThe API has **no limits** today.\n\n1. Add a `RateLimiter`\n2. Return `429`\n\n> Not websockets.\n\nWe will leverage a very robust approach."
            let session = ReviewSession(request: ReviewRequest(
                content: .text(source, format: .markdown), origin: .agentRequest, reply: .stdout, modes: [.feedback, .applyEdits]
            ))
            session.announce = { _ in }
            let window = SnapshotWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ReviewView(session: session) { _ in })
            func settle() {
                window.contentView?.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                window.contentView?.layoutSubtreeIfNeeded()
            }
            settle()
            let textView = try #require(findTextView(in: window.contentView))
            func span(_ words: String) throws -> TextSpan {
                let range = (textView.string as NSString).range(of: words)
                return try #require(session.sourceSpan(forView: range.location..<NSMaxRange(range)))
            }
            func expectFresh(_ step: String) {
                let fresh = NSTextStorage()
                fresh.setAttributedString(TextStyler.attributedString(layout: session.layout, marks: session.marks, selectedMarkID: session.selectedMarkID))
                #expect(textView.textStorage?.isEqual(to: fresh) == true, "after \(step)")
            }

            let struck = try #require(session.addMark(.delete, span: try span("no limits")))
            settle(); expectFresh("a strike")
            let placed = try #require(session.replaceInPlace(span: try span("leverage")))
            settle()
            var caret = placed.caret
            for letter in ["u", "s", "e"] { caret = session.type(letter, atView: caret) ?? caret }
            settle(); expectFresh("a replacement typed")
            // At the start of a list item's words, where they take the item's paragraph style.
            caret = session.type("\n", atView: (textView.string as NSString).range(of: "Add a").location) ?? 0
            settle(); expectFresh("a line typed at the start of a list item")
            session.addMark(.comment, span: try span("RateLimiter"), note: "Name?")
            settle(); expectFresh("a comment")
            let end = (textView.string as NSString).length
            let pinned = try #require(session.addMark(.comment, anchor: session.pointAnchor(atView: end), note: "And then?"))
            session.addMark(.comment, anchor: session.pointAnchor(atView: (textView.string as NSString).range(of: "Not websockets").location), note: "Why not?")
            settle(); expectFresh("comments pinned to points")
            session.remove(pinned.id)
            settle(); expectFresh("a pinned comment removed")
            session.selectedMarkID = struck.id
            settle(); expectFresh("another mark selected")
            session.remove(struck.id)
            settle(); expectFresh("a mark removed")
        }
    }
}
