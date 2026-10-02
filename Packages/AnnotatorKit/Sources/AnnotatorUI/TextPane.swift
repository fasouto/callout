import AnnotatorCore
import AppKit
import SwiftUI

/// The annotation surface for text content.
struct TextPane: NSViewRepresentable {
    let session: ReviewSession
    /// Read by the parent so SwiftUI calls `updateNSView` when the session changes.
    let revision: Int
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = AnnotationTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? AnnotationTextView else { return scrollView }
        context.coordinator.attach(textView, in: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.refresh(revision: revision)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let session: ReviewSession
        private let onCancel: () -> Void
        private weak var textView: AnnotationTextView?
        private weak var scrollView: NSScrollView?
        private var shownRevision = -1
        private var shownSelection: UUID?
        private var shownLayout: DisplayLayout?
        private var isRestyling = false
        private lazy var toolbar = SelectionToolbar { [weak self] kind in self?.perform(kind) }
        private let editor = MarkEditorPopover()

        init(session: ReviewSession, onCancel: @escaping () -> Void) {
            self.session = session
            self.onCancel = onCancel
        }

        func attach(_ textView: AnnotationTextView, in scrollView: NSScrollView) {
            self.textView = textView
            self.scrollView = scrollView

            textView.delegate = self
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
            textView.textContainerInset = NSSize(width: 28, height: 24)
            textView.drawsBackground = true
            textView.backgroundColor = .textBackgroundColor

            textView.onMarkKey = { [weak self] kind in self?.perform(kind) }
            textView.onDeleteKey = { [weak self] in self?.removeSelectedMark() }
            textView.onCancelKey = { [weak self] in self?.onCancel() }
            textView.onSelectionSettled = { [weak self] in self?.selectionSettled() }

            scrollView.hasVerticalScroller = true
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification, object: scrollView.contentView
            )
            refresh(revision: session.revision)
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }

        // MARK: Drawing

        func refresh(revision: Int) {
            guard revision != shownRevision, let textView else { return }
            shownRevision = revision

            let origin = scrollView?.contentView.bounds.origin
            // The caret is an offset into the text shown so far, ghosts of the old marks included.
            let caret = (shownLayout ?? session.layout).displayedOffset(forView: textView.selectedRange().location)
            shownLayout = session.layout
            let styled = TextStyler.attributedString(
                layout: session.layout, marks: session.marks, selectedMarkID: session.selectedMarkID
            )
            isRestyling = true
            textView.textStorage?.setAttributedString(styled)
            // Marks add and remove ghost text, so the caret is kept by its place in the document.
            let location = min(session.layout.viewOffset(forDisplayed: caret), styled.length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            isRestyling = false
            if let origin { scrollView?.contentView.scroll(to: origin) }

            if session.selectedMarkID != shownSelection {
                shownSelection = session.selectedMarkID
                if let mark = session.selectedMark { reveal(mark) }
            }
            toolbar.hide()
        }

        private func viewRange(of mark: Mark) -> NSRange? {
            if let range = session.layout.viewRanges(forSource: mark.anchor.span).first { return NSRange(range) }
            if let ghost = session.layout.ghosts.first(where: { $0.markID == mark.id }) { return NSRange(ghost.range) }
            return nil
        }

        private func reveal(_ mark: Mark) {
            guard let textView, let range = viewRange(of: mark) else { return }
            textView.scrollRangeToVisible(range)
        }

        // MARK: Selection

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isRestyling else { return }
            // While the mouse is down the selection is still being dragged out.
            if NSEvent.pressedMouseButtons == 0 { selectionSettled() }
        }

        private func selectionSettled() {
            guard let textView else { return }
            let selection = textView.selectedRange()
            guard selection.length > 0 else {
                toolbar.hide()
                // A click on marked text selects that mark in the side panel.
                if let mark = session.mark(atView: selection.location) {
                    shownSelection = mark.id
                    session.selectedMarkID = mark.id
                }
                return
            }
            guard let range = Range(selection), session.sourceSpan(forView: range) != nil,
                  let rect = textView.rect(forCharacterRange: selection) else {
                toolbar.hide()
                return
            }
            toolbar.show(above: rect, in: textView)
        }

        @objc private func didScroll() {
            toolbar.hide()
        }

        // MARK: Actions

        func perform(_ kind: MarkKind) {
            guard let textView, let selection = Range(textView.selectedRange()) else { return }
            toolbar.hide()

            if kind == .insert {
                // With a selection, the new text goes after it.
                guard let offset = session.sourceOffset(forView: selection.upperBound) else {
                    session.statusMessage = "Place the caret in the document first."
                    return
                }
                let caret = NSRange(location: selection.upperBound, length: 0)
                edit(kind, at: caret) { [session] text, _ in
                    guard let text = text?.nilIfBlank else { return }
                    session.addMark(.insert, span: TextSpan(offset, offset), text: text)
                }
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
            case .replace:
                edit(kind, at: NSRange(selection)) { [session] text, _ in
                    guard let text else { return }
                    session.addMark(.replace, span: span, text: text)
                }
            case .comment:
                edit(kind, at: NSRange(selection)) { [session] _, note in
                    guard let note = note?.nilIfBlank else { return }
                    session.addMark(.comment, span: span, note: note)
                }
            case .insert:
                break
            }
        }

        private func edit(_ kind: MarkKind, at range: NSRange, commit: @escaping (_ text: String?, _ note: String?) -> Void) {
            guard let textView else { return }
            let rect = textView.rect(forCharacterRange: range) ?? textView.visibleRect
            editor.show(kind: kind, relativeTo: rect, of: textView) { [weak textView] value in
                if let value, kind == .comment {
                    commit(nil, value)
                } else if let value {
                    commit(value, nil)
                }
                textView?.window?.makeFirstResponder(textView)
            }
        }

        private func removeSelectedMark() {
            guard let id = session.selectedMarkID else { return }
            session.remove(id)
        }
    }
}
