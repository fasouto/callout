import Foundation

public enum MarkKind: String, Codable, Sendable, CaseIterable {
    case delete
    case replace
    case insert
    case comment
    case keep

    /// Whether the mark changes the text when edits are applied.
    public var isEdit: Bool {
        switch self {
        case .delete, .replace, .insert: true
        case .comment, .keep: false
        }
    }
}

/// Where a mark sits. The span is a position hint; the quote and its context are
/// what identify the text, so a mark survives re-rendering and revised content.
public struct Anchor: Codable, Hashable, Sendable {
    /// 1-based page number for PDFs, nil for text content.
    public var page: Int?
    /// Offsets into the source text, or into the page's text for PDFs. Empty for inserts.
    public var span: TextSpan
    /// The exact text covered by `span`. Empty for inserts.
    public var quote: String
    public var prefix: String
    public var suffix: String

    public init(page: Int? = nil, span: TextSpan, quote: String, prefix: String = "", suffix: String = "") {
        self.page = page
        self.span = span
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
    }

    public static let contextLength = 32

    /// Builds an anchor for `span` in `text`, capturing the quote and its surroundings.
    public static func make(in text: String, span: TextSpan, page: Int? = nil) -> Anchor? {
        guard let quote = text.slice(span) else { return nil }
        let total = text.utf16Length
        return Anchor(
            page: page,
            span: span,
            quote: quote,
            prefix: text.nearestSlice(max(0, span.start - contextLength), span.start),
            suffix: text.nearestSlice(span.end, min(total, span.end + contextLength))
        )
    }
}

public struct Mark: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: MarkKind
    public var anchor: Anchor
    /// The replacement for `replace`, the new text for `insert`.
    public var text: String?
    /// The reason for `delete` and `replace`, the comment for `comment`.
    public var note: String?

    public init(id: UUID = UUID(), kind: MarkKind, anchor: Anchor, text: String? = nil, note: String? = nil) {
        self.id = id
        self.kind = kind
        self.anchor = anchor
        self.text = text
        self.note = note
    }
}

/// What the marks refer to, as text the formatter can search.
public enum ReviewDocument: Equatable, Sendable {
    case text(String)
    /// One string per page, in page order.
    case pdf(pages: [String])

    /// The text an anchor's span is measured against.
    func scope(for anchor: Anchor) -> String? {
        switch self {
        case .text(let text):
            return text
        case .pdf(let pages):
            guard let page = anchor.page, pages.indices.contains(page - 1) else { return nil }
            return pages[page - 1]
        }
    }

    var isPDF: Bool {
        if case .pdf = self { return true }
        return false
    }
}

extension String {
    /// Like `slice`, but moves the bounds inward when they would split a scalar.
    func nearestSlice(_ start: Int, _ end: Int) -> String {
        var lower = start
        var upper = end
        while lower < upper {
            if let text = slice(TextSpan(lower, upper)) { return text }
            if slice(TextSpan(lower, lower)) == nil { lower += 1 } else { upper -= 1 }
        }
        return ""
    }
}
