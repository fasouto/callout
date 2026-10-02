import AnnotatorCore
import Foundation
import Observation

/// One review in progress: the document, the marks made so far, and what to
/// send back. Everything the review window shows comes from here.
@MainActor
@Observable
final class ReviewSession {
    let request: ReviewRequest
    let source: String
    let document: RenderedDocument

    private(set) var marks: [Mark] = []
    private(set) var layout: DisplayLayout
    /// Bumped whenever the text view has to redraw.
    private(set) var revision = 0
    var generalComment = ""
    var selectedMarkID: UUID? {
        didSet { if selectedMarkID != oldValue { revision += 1 } }
    }
    /// A short note for the status line, such as why an action did nothing.
    var statusMessage: String?

    init(request: ReviewRequest) {
        self.request = request
        switch request.content {
        case .text(let text, let format):
            source = text
            document = MarkdownRenderer.render(text, format: format)
        case .file:
            // PDFs get their own view; until then a file request shows as empty text.
            source = ""
            document = RenderedDocument(plain: "")
        }
        layout = DisplayLayout(document: document, marks: [])
    }

    var title: String {
        if let title = request.metadata.title, !title.isEmpty { return title }
        if let path = request.metadata.filePath { return URL(fileURLWithPath: path).lastPathComponent }
        return "Text"
    }

    /// Marks in the order they appear in the document.
    var orderedMarks: [Mark] {
        marks.enumerated().sorted { lhs, rhs in
            (lhs.element.anchor.span.start, lhs.offset) < (rhs.element.anchor.span.start, rhs.offset)
        }.map(\.element)
    }

    var selectedMark: Mark? {
        marks.first { $0.id == selectedMarkID }
    }

    var allows: (feedback: Bool, applyEdits: Bool, approve: Bool) {
        (request.modes.contains(.feedback), request.modes.contains(.applyEdits), request.modes.contains(.approve))
    }

    // MARK: - Selections

    /// The source behind a selection in the view, or nil when it covers no document text.
    func sourceSpan(forView range: Range<Int>) -> TextSpan? {
        let displayed = layout.displayedRange(forView: range)
        return document.sourceSpan(forDisplayed: displayed)
    }

    func sourceOffset(forView offset: Int) -> Int? {
        document.sourceOffset(forDisplayed: layout.displayedOffset(forView: offset))
    }

    /// The mark whose text contains a view offset, edits before comments.
    func mark(atView offset: Int) -> Mark? {
        let hits = marks.filter { mark in
            if layout.ghosts.contains(where: { $0.markID == mark.id && $0.range.contains(offset) }) { return true }
            return layout.viewRanges(forSource: mark.anchor.span).contains { $0.contains(offset) }
        }
        return hits.first { $0.kind.isEdit } ?? hits.first
    }

    // MARK: - Editing marks

    /// Adds a mark over a source span. Returns nil, with a status message, when it cannot be placed.
    @discardableResult
    func addMark(_ kind: MarkKind, span: TextSpan, text: String? = nil, note: String? = nil) -> Mark? {
        guard let anchor = Anchor.make(in: source, span: span) else {
            statusMessage = "That selection can't be marked."
            return nil
        }
        let mark = Mark(kind: kind, anchor: anchor, text: text, note: note?.nilIfBlank)
        if EditApplier.conflict(of: mark, with: marks) != nil {
            statusMessage = "That overlaps another edit. Remove it first."
            return nil
        }
        marks.append(mark)
        statusMessage = nil
        selectedMarkID = mark.id
        marksChanged()
        return mark
    }

    func update(_ id: UUID, text: String? = nil, note: String? = nil) {
        guard let index = marks.firstIndex(where: { $0.id == id }) else { return }
        if let text { marks[index].text = text }
        if let note { marks[index].note = note.nilIfBlank }
        marksChanged()
    }

    func remove(_ id: UUID) {
        guard let index = marks.firstIndex(where: { $0.id == id }) else { return }
        let ordered = orderedMarks
        let position = ordered.firstIndex { $0.id == id } ?? 0
        marks.remove(at: index)
        // Keep the keyboard flowing: select the neighbour.
        if selectedMarkID == id {
            let remaining = orderedMarks
            selectedMarkID = remaining.isEmpty ? nil : remaining[min(position, remaining.count - 1)].id
        }
        marksChanged()
    }

    private func marksChanged() {
        layout = DisplayLayout(document: document, marks: marks)
        revision += 1
    }

    // MARK: - Output

    var hasFeedback: Bool {
        !marks.isEmpty || !generalComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasEdits: Bool {
        marks.contains { $0.kind.isEdit }
    }

    func feedback() -> String {
        FeedbackFormatter.format(.init(
            title: title, document: .text(source), marks: marks, generalComment: generalComment
        ))
    }

    func editedText() throws -> String {
        try EditApplier.apply(marks, to: source)
    }
}

extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

extension MarkKind {
    var label: String {
        switch self {
        case .delete: "Delete"
        case .replace: "Replace"
        case .insert: "Insert"
        case .comment: "Comment"
        case .keep: "Keep"
        }
    }

    var key: String {
        switch self {
        case .delete: "D"
        case .replace: "R"
        case .insert: "I"
        case .comment: "C"
        case .keep: "K"
        }
    }

    var symbol: String {
        switch self {
        case .delete: "strikethrough"
        case .replace: "arrow.left.arrow.right"
        case .insert: "text.insert"
        case .comment: "text.bubble"
        case .keep: "checkmark.seal"
        }
    }

    init?(key: String) {
        guard let kind = MarkKind.allCases.first(where: { $0.key.lowercased() == key.lowercased() }) else { return nil }
        self = kind
    }
}
