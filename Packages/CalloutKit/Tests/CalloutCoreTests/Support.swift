import Foundation
@testable import CalloutCore

/// The span of the nth occurrence (1-based) of `quote` in `text`.
func span(of quote: String, in text: String, occurrence: Int = 1) -> TextSpan {
    let starts = text.occurrences(of: quote)
    precondition(starts.count >= occurrence, "\"\(quote)\" occurs \(starts.count) times")
    return TextSpan(starts[occurrence - 1], starts[occurrence - 1] + quote.utf16.count)
}

/// A mark on the nth occurrence of `quote`.
func mark(
    _ kind: MarkKind,
    _ quote: String,
    in text: String,
    occurrence: Int = 1,
    page: Int? = nil,
    text replacement: String? = nil,
    note: String? = nil
) -> Mark {
    let anchor = Anchor.make(in: text, span: span(of: quote, in: text, occurrence: occurrence), page: page)!
    return Mark(kind: kind, anchor: anchor, text: replacement, note: note)
}

/// The point right after the nth occurrence of `preceding`, or the start of
/// the text when `preceding` is empty.
func point(after preceding: String, in text: String, occurrence: Int = 1, page: Int? = nil) -> Anchor {
    let offset = preceding.isEmpty ? 0 : span(of: preceding, in: text, occurrence: occurrence).end
    return Anchor.make(in: text, span: TextSpan(offset, offset), page: page)!
}

/// An insert mark placed right after the nth occurrence of `preceding`,
/// or at the start of the text when `preceding` is empty.
func insert(
    _ new: String,
    after preceding: String,
    in text: String,
    occurrence: Int = 1,
    page: Int? = nil
) -> Mark {
    Mark(kind: .insert, anchor: point(after: preceding, in: text, occurrence: occurrence, page: page), text: new)
}
