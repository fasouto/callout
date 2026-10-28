import AnnotatorCore
import AppKit
import Observation
import SwiftUI

/// Where each margin note belongs, as worked out from the text's layout.
@MainActor
@Observable
final class MarginModel {
    /// Distance from the top of the page to the line each mark starts on.
    var anchors: [UUID: CGFloat] = [:]
    /// Where the line from each mark to its note starts, from the top left of
    /// the page. Only a PDF has them: its notes sit on the desk, away from the words.
    var leaders: [UUID: CGPoint] = [:]
    /// Where the first line of the document sits, for the empty margin's guide.
    var firstLine: CGFloat = 0
    /// Whether changes may be animated: only once the window is on screen.
    var animates = false
    /// How tall the notes are once stacked. The page grows to fit them.
    var contentHeight: CGFloat = 0 {
        didSet { if abs(contentHeight - oldValue) > 0.5 { onContentHeightChange?() } }
    }
    @ObservationIgnored var onContentHeightChange: (() -> Void)?
}

/// One sheet inside the scroll view: the text column and, beside it, the margin.
final class PageView: NSView {
    override var isFlipped: Bool { true }
}

/// The annotation surface for text content: the page and its margin.
struct DocumentPane: NSViewRepresentable {
    let session: ReviewSession
    /// Read by the parent so SwiftUI calls `updateNSView` when the session changes.
    let revision: Int
    let focusToken: Int
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.refresh(revision: revision)
        context.coordinator.focusDocument(token: focusToken)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSAccessibilityCustomRotorItemSearchDelegate {
        private let session: ReviewSession
        private let onCancel: () -> Void
        private let margin = MarginModel()
        private let decorator = BlockDecorator()
        private var textView: AnnotationTextView!
        private var scrollView: NSScrollView!
        private var page: PageView!
        private var marginHost: NSView!
        private var shownRevision = -1
        private var shownSelection: UUID?
        private var shownLayout: DisplayLayout?
        private var styledPage: StyledPage?
        /// How wide the text column is; a table wider than it is set smaller.
        private var measure = Theme.measure
        private var shownFocusToken = 0
        private var isRestyling = false
        private var laidOutWidth: CGFloat = -1
        /// Where the text still waits to be laid out at this width; nil once all of it is.
        private var unlaidFrom: Int?
        /// Bumped whenever layout starts over, so a part left from before is not laid out.
        private var layoutRound = 0
        private lazy var toolbar = SelectionToolbar(
            perform: { [weak self] kind in self?.perform(kind) },
            pickSnippet: { [weak self] in self?.pickSnippet() }
        )
        private let snippetPicker = SnippetPickerPopover()

        init(session: ReviewSession, onCancel: @escaping () -> Void) {
            self.session = session
            self.onCancel = onCancel
        }

        func makeScrollView() -> NSScrollView {
            let textView = AnnotationTextView(usingTextLayoutManager: true)
            self.textView = textView
            textView.delegate = self
            textView.textLayoutManager?.delegate = decorator
            textView.isEditable = true
            textView.isRichText = true
            textView.allowsUndo = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isContinuousSpellCheckingEnabled = false
            textView.isGrammarCheckingEnabled = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticLinkDetectionEnabled = false
            textView.drawsBackground = false
            textView.textContainerInset = .zero
            textView.textContainer?.lineFragmentPadding = 0
            textView.textContainer?.widthTracksTextView = true
            // The page sizes the text view; it must not resize itself.
            textView.isVerticallyResizable = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = []
            textView.setAccessibilityLabel("Document")

            // VoiceOver's rotor goes from mark to mark, each read as what it is.
            textView.setAccessibilityCustomRotors([NSAccessibilityCustomRotor(label: "Marks", itemSearchDelegate: self)])
            textView.onCommand = { [weak self] command in self?.run(command) }
            textView.onVisualModeChange = { [weak self] isOn in self?.session.isSelectingByKeyboard = isOn }
            textView.onInsertModeChange = { [weak self] isOn in self?.session.isTypingMode = isOn }
            textView.onType = { [weak self] text in self?.type(text) }
            textView.onTypeOnSelection = { [weak self] text in self?.comment(typing: text) }
            textView.isHandingKeysToField = { [weak self] in self?.session.isHandingKeyboardToField ?? false }
            textView.onFieldKey = { [weak self] key in self?.session.press(key) }
            textView.onDeleteCharacter = { [weak self] forward in self?.deleteCharacter(forward: forward) }
            textView.onDeleteKey = { [weak self] in self?.removeSelectedMark() }
            textView.onRemoveMark = { [weak self] in
                guard let self, let id = self.session.selectedMarkID else { return }
                self.session.remove(id)
            }
            textView.onReturnKey = { [weak self] in self?.editSelectedMark() }
            textView.onTabKey = { [weak self] forward in self?.session.selectMark(offsetBy: forward ? 1 : -1) }
            textView.onCancelKey = { [weak self] in self?.onCancel() }
            textView.onSelectionSettled = { [weak self] in self?.selectionSettled() }

            let host = NSHostingView(rootView: MarginNotes(session: session, model: margin))
            host.sizingOptions = []
            marginHost = host
            // Notes growing or shrinking change the page's height, not its text.
            margin.onContentHeightChange = { [weak self] in self?.layoutPage(changed: []) }

            let page = PageView()
            self.page = page
            page.addSubview(textView)
            page.addSubview(host)

            let scrollView = NSScrollView()
            self.scrollView = scrollView
            scrollView.documentView = page
            scrollView.hasVerticalScroller = true
            scrollView.drawsBackground = false
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.contentView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification, object: scrollView.contentView
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(didResize), name: NSView.frameDidChangeNotification, object: scrollView.contentView
            )

            refresh(revision: session.revision)
            return scrollView
        }

        // MARK: Drawing

        func refresh(revision: Int) {
            guard revision != shownRevision else { return }
            shownRevision = revision

            let origin = scrollView.contentView.bounds.origin
            // The caret is an offset into the text shown so far, ghosts of the old marks included.
            let caret = (shownLayout ?? session.layout).displayedOffset(forView: textView.selectedRange().location)
            shownLayout = session.layout
            guard let storage = textView.textStorage else { return }
            let added = session.shownChanges?.added ?? []
            isRestyling = true
            // Only the parts of the page that changed are set again: a whole page
            // costs seconds on a long document, and the text view's layout with it.
            let edits = styledPage?.update(
                to: session.layout, marks: session.marks, selectedMarkID: session.selectedMarkID, added: added, measure: measure
            )
            if let edits {
                storage.beginEditing()
                for edit in edits { storage.replaceCharacters(in: edit.range, with: edit.text) }
                storage.endEditing()
            } else {
                let made = StyledPage(
                    layout: session.layout, marks: session.marks, selectedMarkID: session.selectedMarkID, added: added, measure: measure
                )
                styledPage = made
                storage.setAttributedString(made.text)
            }
            // Marks add and remove ghost text, so the caret is kept by its place in the document.
            let location = min(session.layout.viewOffset(forDisplayed: caret), storage.length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            isRestyling = false

            // A note's words change the margin only; the page and where it is stay as they were.
            if edits?.isEmpty != true {
                layoutPage(changed: edits.map(Self.changedRanges))
                scrollView.contentView.scroll(to: origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }

            if session.selectedMarkID != shownSelection {
                shownSelection = session.selectedMarkID
                if let mark = session.selectedMark { reveal(mark) }
            }
            toolbar.hide()
        }

        func focusDocument(token: Int) {
            guard token != shownFocusToken else { return }
            shownFocusToken = token
            textView.window?.makeFirstResponder(textView)
        }

        /// Where the edits are once made, in the page as it is now.
        private static func changedRanges(_ edits: [StyledPage.Edit]) -> [NSRange] {
            var shift = 0
            return edits.sorted { $0.range.location < $1.range.location }.map { edit in
                defer { shift += edit.text.length - edit.range.length }
                return NSRange(location: edit.range.location + shift, length: edit.text.length)
            }
        }

        /// Places the text column and the margin, and tells the margin where each note goes.
        /// - Parameter changed: the parts of the page that changed since it was last
        ///   laid out at this width; nil to lay out all of it.
        private func layoutPage(changed: [NSRange]? = nil) {
            let clip = scrollView.contentView.bounds.size
            guard clip.width > 0 else { return }
            // A new width lays every line out anew.
            let ensuring = clip.width == laidOutWidth ? changed : nil
            laidOutWidth = clip.width

            // The margin gives way first, then the measure.
            let roomy = clip.width >= Theme.measure + Theme.gutter + Theme.marginWidth + 2 * Theme.pageSide
            let marginWidth = roomy ? Theme.marginWidth : Theme.narrowMarginWidth
            let side = roomy ? Theme.pageSide : 24
            let measure = max(Theme.minimumMeasure, min(Theme.measure, clip.width - marginWidth - Theme.gutter - 2 * side))
            let left = max(side, ((clip.width - measure - Theme.gutter - marginWidth) / 2).rounded())
            if measure != self.measure {
                self.measure = measure
                resetForMeasure()
            }

            textView.setFrameSize(NSSize(width: measure, height: max(textView.frame.height, 10)))
            let textHeight = ensuring.map { textView.layoutHeight(ensuring: $0) } ?? layOutFromTheTop()
            textView.frame = NSRect(x: left, y: Theme.pageTop, width: measure, height: textHeight)

            updateAnchors()
            let height = max(
                Theme.pageTop + textHeight + Theme.pageBottom,
                margin.contentHeight + Theme.pageBottom,
                clip.height
            )
            marginHost.frame = NSRect(x: left + measure + Theme.gutter, y: 0, width: marginWidth, height: height)
            page.frame = NSRect(x: 0, y: 0, width: clip.width, height: height)
        }

        /// A table that no longer fits the column, or now fits it better, is set
        /// again at its new size. The text stays the same, and so does the selection in it.
        private func resetForMeasure() {
            guard let page = styledPage, !page.suits(measure: measure), let storage = textView.textStorage else { return }
            let made = page.set(for: measure)
            styledPage = made
            let selection = textView.selectedRanges
            isRestyling = true
            storage.setAttributedString(made.text)
            textView.selectedRanges = selection
            isRestyling = false
        }

        /// A long text opens at once: its start is laid out now and the rest a
        /// part at a time once the page is up, between whatever else happens.
        /// Until then its height is the layout manager's estimate.
        private static let laidOutAtOnce = 50_000
        /// Laid out in pieces of this many characters, for this long at a time:
        /// short enough that typing or scrolling meanwhile does not stutter.
        private static let layoutPiece = 4_000
        private static let layoutTurn = Duration.milliseconds(12)

        private func layOutFromTheTop() -> CGFloat {
            layoutRound += 1
            let length = textView.textStorage?.length ?? 0
            guard length > Self.laidOutAtOnce else {
                unlaidFrom = nil
                return textView.layoutHeight()
            }
            unlaidFrom = Self.laidOutAtOnce
            layOutMoreSoon()
            return textView.layoutHeight(ensuring: [NSRange(location: 0, length: Self.laidOutAtOnce)])
        }

        private func layOutMoreSoon() {
            let round = layoutRound
            // On the run loop in its common modes, so the layout goes on while
            // the page is being scrolled or the window resized.
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated { self?.layOutMore(round: round) }
            }
        }

        private func layOutMore(round: Int) {
            guard round == layoutRound, var from = unlaidFrom, textView.window != nil else { return }
            let length = textView.textStorage?.length ?? 0
            let clock = ContinuousClock()
            let start = clock.now
            while from < length, clock.now - start < Self.layoutTurn {
                let upTo = min(length, from + Self.layoutPiece)
                _ = textView.layoutHeight(ensuring: [NSRange(location: from, length: upTo - from)])
                from = upTo
            }
            unlaidFrom = from < length ? from : nil
            // The page grows or shrinks to what is known so far, and is exact once all of it is.
            layoutPage(changed: [])
            if unlaidFrom != nil { layOutMoreSoon() }
        }

        private func updateAnchors() {
            let onScreen = textView.window?.isVisible == true
            if margin.animates != onScreen { margin.animates = onScreen }
            var anchors: [UUID: CGFloat] = [:]
            for mark in session.marks {
                guard let range = viewRange(of: mark), let rect = textView.rect(forCharacterRange: range) else { continue }
                // The middle of the line, so a note lines up with headings and body text alike.
                anchors[mark.id] = textView.frame.minY + rect.midY
            }
            if margin.anchors != anchors { margin.anchors = anchors }
            let first = textView.frame.minY + (textView.rect(forCharacterRange: NSRange(location: 0, length: 0))?.midY ?? 0)
            if margin.firstLine != first { margin.firstLine = first }
        }

        /// Where a mark is in the view: its text, its ghost, or the caret of an empty insertion.
        private func viewRange(of mark: Mark) -> NSRange? {
            if let range = session.layout.viewRanges(forSource: mark.anchor.span).first { return NSRange(range) }
            if let ghost = session.layout.ghosts.first(where: { $0.markID == mark.id }) { return NSRange(ghost.range) }
            guard let displayed = session.document.displayedOffset(forSource: mark.anchor.span.start) else { return nil }
            return NSRange(location: session.layout.viewOffset(forDisplayed: displayed), length: 0)
        }

        // MARK: VoiceOver

        /// The marks in document order, as the rotor offers them.
        var rotorItems: [(label: String, range: NSRange)] {
            session.orderedMarks.compactMap { mark in viewRange(of: mark).map { (mark.spokenDescription, $0) } }
        }

        func rotor(
            _ rotor: NSAccessibilityCustomRotor, resultFor parameters: NSAccessibilityCustomRotor.SearchParameters
        ) -> NSAccessibilityCustomRotor.ItemResult? {
            var items = rotorItems
            if !parameters.filterString.isEmpty {
                items = items.filter { $0.label.localizedCaseInsensitiveContains(parameters.filterString) }
            }
            let current = parameters.currentItem?.targetRange.location
            let found: (label: String, range: NSRange)?
            switch parameters.searchDirection {
            case .next:
                found = current.map { at in items.first { $0.range.location > at } } ?? items.first
            case .previous:
                found = current.map { at in items.last { $0.range.location < at } } ?? items.last
            @unknown default:
                found = nil
            }
            guard let found else { return nil }
            let result = NSAccessibilityCustomRotor.ItemResult(targetElement: textView)
            result.targetRange = found.range
            result.customLabel = found.label
            return result
        }

        private func reveal(_ mark: Mark) {
            guard let range = viewRange(of: mark), let rect = textView.rect(forCharacterRange: range) else { return }
            // Leave some of the page around it rather than pinning it to an edge.
            textView.scrollToVisible(rect.insetBy(dx: 0, dy: -60))
        }

        @objc private func didScroll() {
            toolbar.hide()
        }

        @objc private func didResize() {
            if scrollView.contentView.bounds.width != laidOutWidth { layoutPage() }
        }

        // MARK: Selection

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isRestyling, !textView.isMovingByKey else { return }
            // While the mouse is down the selection is still being dragged out.
            if NSEvent.pressedMouseButtons == 0 { selectionSettled() }
        }

        private func selectionSettled() {
            let selection = textView.selectedRange()
            // Back in the document: whatever was being written in the margin is done.
            if session.editing != nil, textView.window?.firstResponder === textView { session.endEditing() }
            guard selection.length > 0 else {
                toolbar.hide()
                session.selection = session.sourceOffset(forView: selection.location) == nil ? .none : .caret
                // A click on marked text selects that mark; a click elsewhere lets go of it.
                let mark = session.mark(atView: selection.location)
                shownSelection = mark?.id
                session.selectedMarkID = mark?.id
                return
            }
            guard let range = Range(selection), session.sourceSpan(forView: range) != nil,
                  let rect = textView.rect(forCharacterRange: selection) else {
                toolbar.hide()
                session.selection = .none
                return
            }
            session.selection = .range
            toolbar.show(above: rect, in: textView)
        }

        // MARK: Typing

        /// Redraws right away and puts the caret where typing left it. The usual
        /// redraw waits for SwiftUI, which is too late for the next key.
        private func redraw(caret: Int) {
            refresh(revision: session.revision)
            let location = min(caret, (textView.string as NSString).length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.scrollRangeToVisible(NSRange(location: location, length: 0))
        }

        private func type(_ text: String) {
            let selection = textView.selectedRange()
            guard selection.length == 0, let caret = session.type(text, atView: selection.location) else {
                if session.statusMessage == nil { session.statusMessage = "Text can't be added here." }
                NSSound.beep()
                return
            }
            redraw(caret: caret)
        }

        /// Words typed on a selection are a comment on it.
        private func comment(typing text: String) {
            toolbar.hide()
            let span = Range(textView.selectedRange()).flatMap { session.sourceSpan(forView: $0) }
            session.comment(typing: text, anchor: span.flatMap { Anchor.make(in: session.source, span: $0) })
        }

        private func deleteCharacter(forward: Bool) {
            let selection = textView.selectedRange()
            guard selection.length == 0,
                  let caret = session.deleteCharacter(atView: selection.location, forward: forward) else { return }
            redraw(caret: caret)
        }

        // MARK: Actions

        func run(_ command: Keymap.Command) {
            switch command {
            case .mark(let kind): perform(kind)
            case .snippets: pickSnippet()
            case .overall: session.focusOverallComment()
            }
        }

        /// - Parameter writingNote: whether the keyboard goes to the new mark's
        ///   note. Not for ⌫, which strikes as an editor deletes.
        func perform(_ kind: MarkKind, writingNote: Bool = true) {
            guard let selection = Range(textView.selectedRange()) else { return }
            toolbar.hide()

            if kind == .insert {
                // The new text is typed in place: after the selection, or at the caret.
                guard session.sourceOffset(forView: selection.upperBound) != nil else {
                    session.statusMessage = "Place the caret in the document first."
                    return
                }
                textView.setSelectedRange(NSRange(location: selection.upperBound, length: 0))
                textView.beginTyping()
                return
            }

            guard !selection.isEmpty, let span = session.sourceSpan(forView: selection) else {
                session.statusMessage = "Select some text of the document first."
                NSSound.beep()
                return
            }
            switch kind {
            case .delete where writingNote:
                // Ready for the reason, as a comment is; ↩ or Esc goes on without one.
                session.addMarkToWrite(kind, span: span)
            case .delete, .keep, .expand, .summarize:
                session.addMark(kind, span: span)
            case .replace:
                // The replacement is typed in place, right after the struck text.
                if let placed = session.replaceInPlace(span: span) {
                    redraw(caret: placed.caret)
                    textView.beginTyping()
                }
            case .comment:
                session.addMarkToWrite(kind, span: span)
            case .insert:
                break
            }
        }

        /// Comments on the selection with a reusable comment chosen from the picker.
        func pickSnippet() {
            guard let selection = Range(textView.selectedRange()), !selection.isEmpty,
                  let span = session.sourceSpan(forView: selection) else {
                session.statusMessage = "Select some text of the document first."
                NSSound.beep()
                return
            }
            toolbar.hide()
            let rect = textView.rect(forCharacterRange: NSRange(selection)) ?? textView.visibleRect
            snippetPicker.show(
                snippets: session.loadSnippets(), preferred: .preferred(for: session.request), relativeTo: rect, of: textView
            ) { [weak self] snippet in
                guard let self else { return }
                if let snippet { self.session.addComment(from: snippet, anchor: Anchor.make(in: self.session.source, span: span)) }
                self.textView.window?.makeFirstResponder(self.textView)
            }
        }

        /// ⌫ strikes out the selected text, as it would delete it in an editor.
        /// On text that is already struck, it takes the strike back; with nothing
        /// selected, it removes the mark the caret is on.
        private func removeSelectedMark() {
            if let selection = Range(textView.selectedRange()), !selection.isEmpty,
               let span = session.sourceSpan(forView: selection) {
                if let struck = session.marks.first(where: { $0.kind == .delete && $0.anchor.span == span }) {
                    session.remove(struck.id)
                } else {
                    perform(.delete, writingNote: false)
                }
                return
            }
            guard let id = session.selectedMarkID else { return }
            session.remove(id)
        }

        private func editSelectedMark() {
            guard let id = session.selectedMarkID else { return }
            session.beginEditing(id)
        }
    }
}
