import Foundation

public enum EditError: Error, Equatable {
    /// The mark's quote is no longer in the text.
    case anchorNotFound(UUID)
    /// Two edits touch the same text.
    case overlapping(UUID, UUID)
}

/// Applies delete, replace and insert marks to a source text. Comments and keeps
/// are ignored, as are marks anchored to a PDF page.
public enum EditApplier {
    /// - Parameter tidy: clean up what a deletion leaves behind (doubled spaces,
    ///   a space before punctuation, an emptied line or list item).
    public static func apply(_ marks: [Mark], to source: String, tidy: Bool = true) throws -> String {
        let edits = try resolvedEdits(marks, in: source)
        let text = NSMutableString(string: source)

        // Back to front, so earlier offsets stay valid.
        for index in edits.indices.reversed() {
            let edit = edits[index]
            switch edit.mark.kind {
            case .insert:
                text.insert(edit.mark.text ?? "", at: edit.span.start)
            case .replace:
                text.replaceCharacters(in: NSRange(edit.span), with: edit.mark.text ?? "")
            case .delete:
                var range = NSRange(edit.span)
                if tidy {
                    // Tidying may not reach into text another edit still has to change,
                    // nor swallow what an adjacent edit just put there.
                    let floor = edits[..<index].map(\.span.end).max() ?? 0
                    let next = index + 1 < edits.count ? edits[index + 1].span.start : nil
                    let tidied = DeletionTidier.range(for: edit.span, in: text)
                    let reachesBack = tidied.location < floor
                    let reachesForward = next == edit.span.end && NSMaxRange(tidied) > edit.span.end
                    if !reachesBack && !reachesForward { range = tidied }
                }
                text.deleteCharacters(in: range)
            case .comment, .expand, .summarize, .keep:
                break
            }
        }
        return text as String
    }

    /// Whether `candidate` could be added to `marks` without touching an existing edit.
    public static func conflict(of candidate: Mark, with marks: [Mark]) -> Mark? {
        guard candidate.kind.isEdit else { return nil }
        return marks.first { other in
            other.id != candidate.id && other.kind.isEdit && other.anchor.page == candidate.anchor.page
                && collide(candidate.anchor.span, other.anchor.span)
        }
    }

    private struct Edit {
        var mark: Mark
        var span: TextSpan
        var order: Int
    }

    /// Edits in the order they appear in the text. An insert sorts before a range
    /// edit starting at the same offset, and inserts at one offset keep mark order.
    private static func resolvedEdits(_ marks: [Mark], in source: String) throws -> [Edit] {
        var edits: [Edit] = []
        for (order, mark) in marks.enumerated() where mark.kind.isEdit && mark.anchor.page == nil {
            guard let span = AnchorResolver.resolve(mark.anchor, in: source) else {
                throw EditError.anchorNotFound(mark.id)
            }
            edits.append(Edit(mark: mark, span: span, order: order))
        }
        edits.sort { lhs, rhs in
            if lhs.span.start != rhs.span.start { return lhs.span.start < rhs.span.start }
            if lhs.span.isEmpty != rhs.span.isEmpty { return lhs.span.isEmpty }
            return lhs.order < rhs.order
        }
        for (index, edit) in edits.enumerated() {
            for later in edits[(index + 1)...] where collide(edit.span, later.span) {
                throw EditError.overlapping(edit.mark.id, later.mark.id)
            }
        }
        return edits
    }

    /// Range edits collide when they overlap. An insert collides only when it
    /// falls strictly inside a range edit; inserts never collide with each other.
    private static func collide(_ lhs: TextSpan, _ rhs: TextSpan) -> Bool {
        switch (lhs.isEmpty, rhs.isEmpty) {
        case (true, true): false
        case (true, false): rhs.start < lhs.start && lhs.start < rhs.end
        case (false, true): lhs.start < rhs.start && rhs.start < lhs.end
        case (false, false): lhs.overlaps(rhs)
        }
    }
}

extension NSRange {
    init(_ span: TextSpan) {
        self.init(location: span.start, length: span.length)
    }
}

/// Widens a deletion so it does not leave debris behind.
enum DeletionTidier {
    static func range(for span: TextSpan, in text: NSString) -> NSRange {
        guard !span.isEmpty else { return NSRange(span) }
        if let lines = emptiedLines(by: span, in: text) { return lines }

        var start = span.start
        var end = span.end
        let before = start > 0 ? text.character(at: start - 1) : newline
        let after = end < text.length ? text.character(at: end) : newline

        if isBlank(after), isBlank(before) || isLineBreak(before) || opensEmphasis(text, endingAt: start) {
            // "a |very| good" and "**|very| important**": drop the space that follows.
            end += 1
        } else if isBlank(before),
                  isLineBreak(after) || closingPunctuation.contains(after) || closesEmphasis(text, startingAt: end) {
            // "good |really|.", "foo |bar|\n" and "**very |important|**", but not a
            // two-space hard line break.
            let twoBefore = start > 1 ? text.character(at: start - 2) : newline
            if !isBlank(twoBefore) { start -= 1 }
        }
        return NSRange(location: start, length: end - start)
    }

    /// When the deletion leaves nothing on its lines but a block marker, the
    /// range covering those lines and one line break; otherwise nil.
    private static func emptiedLines(by span: TextSpan, in text: NSString) -> NSRange? {
        let lineStart = text.lineRange(for: NSRange(location: span.start, length: 0)).location
        // A deletion that takes its own line break ends the line right there.
        let takesLineBreak = isLineBreak(text.character(at: span.end - 1))
        var contentsEnd = span.end
        var lineEnd = span.end
        if !takesLineBreak {
            text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: span.end, length: 0))
        }

        let before = text.substring(with: NSRange(location: lineStart, length: span.start - lineStart))
        let after = text.substring(with: NSRange(location: span.end, length: contentsEnd - span.end))
        guard after.allSatisfy(\.isWhitespace), isBlockPrefix(before) else { return nil }

        var range = NSRange(location: lineStart, length: lineEnd - lineStart)
        if !takesLineBreak, lineEnd == contentsEnd, lineStart > 0 {
            // Last line of the text: take the line break before it instead.
            var previousContentsEnd = 0
            text.getLineStart(nil, end: nil, contentsEnd: &previousContentsEnd, for: NSRange(location: lineStart - 1, length: 0))
            range = NSRange(location: previousContentsEnd, length: lineEnd - previousContentsEnd)
        }

        // Removing a paragraph between two blank lines would leave both; drop one.
        let next = NSMaxRange(range)
        if range.location > 0, next < text.length,
           isBlankLine(text, endingAt: range.location), let following = blankLine(text, startingAt: next) {
            range.length += following
        }
        return range
    }

    private static let newline: unichar = 0x0A
    private static let closingPunctuation: Set<unichar> = Set(",.;:!?)]".utf16)
    private static let emphasisDelimiters: Set<unichar> = Set("*_~".utf16)

    /// Whether the delimiters right before `offset` start an emphasised run.
    private static func opensEmphasis(_ text: NSString, endingAt offset: Int) -> Bool {
        var index = offset
        while index > 0, emphasisDelimiters.contains(text.character(at: index - 1)) { index -= 1 }
        guard index < offset else { return false }
        return index == 0 || isBlank(text.character(at: index - 1)) || isLineBreak(text.character(at: index - 1))
    }

    /// Whether the delimiters right at `offset` end an emphasised run.
    private static func closesEmphasis(_ text: NSString, startingAt offset: Int) -> Bool {
        var index = offset
        while index < text.length, emphasisDelimiters.contains(text.character(at: index)) { index += 1 }
        guard index > offset else { return false }
        guard index < text.length else { return true }
        let next = text.character(at: index)
        return isBlank(next) || isLineBreak(next) || closingPunctuation.contains(next)
    }

    private static func isBlank(_ unit: unichar) -> Bool { unit == 0x20 || unit == 0x09 }
    private static func isLineBreak(_ unit: unichar) -> Bool { unit == 0x0A || unit == 0x0D }

    /// Whitespace, quote markers, a list marker, a task box or heading hashes.
    private static func isBlockPrefix(_ text: String) -> Bool {
        text.wholeMatch(of: /[ \t]*(?:>[ \t]*)*(?:(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]*)?|\#{1,6}[ \t]*)?/) != nil
    }

    private static func isQuoteOnly(_ text: String) -> Bool {
        text.wholeMatch(of: /[ \t]*(?:>[ \t]*)*/) != nil
    }

    /// Whether the line that ends at `offset` (a line start) is blank.
    private static func isBlankLine(_ text: NSString, endingAt offset: Int) -> Bool {
        let previous = text.lineRange(for: NSRange(location: offset - 1, length: 0))
        guard NSMaxRange(previous) == offset else { return false }
        return isQuoteOnly(text.substring(with: previous).trimmingCharacters(in: .newlines))
    }

    /// The length of the line starting at `offset`, when it is blank.
    private static func blankLine(_ text: NSString, startingAt offset: Int) -> Int? {
        let line = text.lineRange(for: NSRange(location: offset, length: 0))
        guard line.location == offset else { return nil }
        return isQuoteOnly(text.substring(with: line).trimmingCharacters(in: .newlines)) ? line.length : nil
    }
}
