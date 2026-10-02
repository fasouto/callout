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
    final class Coordinator: NSObject, NSTextViewDelegate {
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
        private var shownFocusToken = 0
        private var isRestyling = false
        private var laidOutWidth: CGFloat = -1
        private lazy var toolbar = SelectionToolbar { [weak self] kind in self?.perform(kind) }

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

            textView.onMarkKey = { [weak self] kind in self?.perform(kind) }
            textView.onDeleteKey = { [weak self] in self?.removeSelectedMark() }
            textView.onReturnKey = { [weak self] in self?.editSelectedMark() }
            textView.onTabKey = { [weak self] forward in self?.session.selectMark(offsetBy: forward ? 1 : -1) }
            textView.onCancelKey = { [weak self] in self?.onCancel() }
            textView.onSelectionSettled = { [weak self] in self?.selectionSettled() }

            let host = NSHostingView(rootView: MarginNotes(session: session, model: margin))
            host.sizingOptions = []
            marginHost = host
            margin.onContentHeightChange = { [weak self] in self?.layoutPage() }

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
            DispatchQueue.main.async { [weak textView] in textView?.window?.makeFirstResponder(textView) }
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
            let styled = TextStyler.attributedString(
                layout: session.layout, marks: session.marks, selectedMarkID: session.selectedMarkID,
                added: session.shownChanges?.added ?? []
            )
            isRestyling = true
            textView.textStorage?.setAttributedString(styled)
            // Marks add and remove ghost text, so the caret is kept by its place in the document.
            let location = min(session.layout.viewOffset(forDisplayed: caret), styled.length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            isRestyling = false

            layoutPage()
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)

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

        /// Places the text column and the margin, and tells the margin where each note goes.
        private func layoutPage() {
            let clip = scrollView.contentView.bounds.size
            guard clip.width > 0 else { return }
            laidOutWidth = clip.width

            // The margin gives way first, then the measure.
            let roomy = clip.width >= Theme.measure + Theme.gutter + Theme.marginWidth + 2 * Theme.pageSide
            let marginWidth = roomy ? Theme.marginWidth : Theme.narrowMarginWidth
            let side = roomy ? Theme.pageSide : 24
            let measure = max(Theme.minimumMeasure, min(Theme.measure, clip.width - marginWidth - Theme.gutter - 2 * side))
            let left = max(side, ((clip.width - measure - Theme.gutter - marginWidth) / 2).rounded())

            textView.setFrameSize(NSSize(width: measure, height: max(textView.frame.height, 10)))
            let textHeight = textView.layoutHeight()
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
            guard !isRestyling else { return }
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

        // MARK: Actions

        func perform(_ kind: MarkKind) {
            guard let selection = Range(textView.selectedRange()) else { return }
            toolbar.hide()

            if kind == .insert {
                // With a selection, the new text goes after it.
                guard let offset = session.sourceOffset(forView: selection.upperBound) else {
                    session.statusMessage = "Place the caret in the document first."
                    return
                }
                session.addMarkToWrite(.insert, span: TextSpan(offset, offset))
                return
            }

            guard !selection.isEmpty, let span = session.sourceSpan(forView: selection) else {
                session.statusMessage = "Select some text of the document first."
                NSSound.beep()
                return
            }
            switch kind {
            case .delete, .keep:
                session.addMark(kind, span: span)
            case .replace, .comment:
                session.addMarkToWrite(kind, span: span)
            case .insert:
                break
            }
        }

        private func removeSelectedMark() {
            guard let id = session.selectedMarkID else { return }
            session.remove(id)
        }

        private func editSelectedMark() {
            guard let id = session.selectedMarkID else { return }
            session.beginEditing(id)
        }
    }
}
