import Foundation

/// Turns marks into markdown an AI can act on. The quoted text is the anchor:
/// the reader has to find it in its own source, so quotes are exact.
public enum FeedbackFormatter {
    public struct Input: Sendable {
        public var title: String
        public var document: ReviewDocument
        public var marks: [Mark]
        public var generalComment: String

        public init(title: String, document: ReviewDocument, marks: [Mark], generalComment: String = "") {
            self.title = title
            self.document = document
            self.marks = marks
            self.generalComment = generalComment
        }
    }

    public static func format(_ input: Input) -> String {
        let ordered = input.marks.enumerated().sorted { lhs, rhs in
            let left = (lhs.element.anchor.page ?? 0, lhs.element.anchor.span.start, lhs.offset)
            let right = (rhs.element.anchor.page ?? 0, rhs.element.anchor.span.start, rhs.offset)
            return left < right
        }.map(\.element)

        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [String] = [title.isEmpty ? "## Feedback" : "## Feedback on \(title)"]

        let general = input.generalComment.trimmingCharacters(in: .whitespacesAndNewlines)
        if ordered.isEmpty && general.isEmpty {
            sections.append("No changes requested.")
            return sections.joined(separator: "\n\n") + "\n"
        }
        if input.document.isPDF, ordered.contains(where: { $0.kind != .keep }) {
            sections.append("Apply these changes to the source this document was generated from, then regenerate it.")
        }

        var number = 0
        for mark in ordered where mark.kind != .keep {
            number += 1
            sections.append(section(for: mark, number: number, in: input.document))
        }

        let keeps = ordered.filter { $0.kind == .keep }
        if !keeps.isEmpty {
            let blocks = keeps.map { mark in
                (quoteLines(for: mark, in: input.document) + noteLines(nil, mark.note)).joined(separator: "\n")
            }
            sections.append("### Keep as is\n" + blocks.joined(separator: "\n\n"))
        }
        if !general.isEmpty {
            sections.append("### General\n" + general)
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Sections

    private static func section(for mark: Mark, number: Int, in document: ReviewDocument) -> String {
        let page = mark.anchor.page.map { " (page \($0))" } ?? ""
        var lines: [String] = []

        switch mark.kind {
        case .replace:
            lines.append("### \(number). Replace\(page)")
            lines += quoteLines(for: mark, in: document)
            lines += labelled("With", mark.text ?? "")
            lines += noteLines("Reason", mark.note)
        case .delete:
            lines.append("### \(number). Delete\(page)")
            lines += quoteLines(for: mark, in: document)
            lines += noteLines("Reason", mark.note)
        case .comment:
            lines.append("### \(number). Comment\(page)")
            lines += quoteLines(for: mark, in: document)
            lines += noteLines(nil, mark.note)
        case .insert:
            let place = insertionContext(for: mark, in: document)
            lines.append("### \(number). Insert\(place.map { " \($0.relation)" } ?? "")\(page)")
            if let place { lines += quoted(place.text) }
            lines += labelled("Add", mark.text ?? "")
            lines += noteLines("Reason", mark.note)
        case .keep:
            break
        }
        return lines.joined(separator: "\n")
    }

    private static func noteLines(_ label: String?, _ note: String?) -> [String] {
        guard let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else { return [] }
        guard let label else { return [note] }
        return labelled(label, note)
    }

    /// `Label: value`, with the value on its own lines when it spans several.
    /// Surrounding whitespace matters when applying an edit, not when describing it.
    private static func labelled(_ label: String, _ value: String) -> [String] {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.contains("\n") ? ["\(label):", value] : ["\(label): \(value)"]
    }

    // MARK: - Quotes

    private static let longQuote = 600
    private static let quoteHead = 300
    private static let quoteTail = 200

    private static func quoteLines(for mark: Mark, in document: ReviewDocument) -> [String] {
        let quote = mark.anchor.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        var shown = quote
        if quote.count > longQuote {
            shown = String(quote.prefix(quoteHead)) + "\n[…]\n" + String(quote.suffix(quoteTail))
        }
        var lines = quoted(shown)
        if let which = disambiguation(for: mark, in: document) { lines.append(which) }
        return lines
    }

    private static func quoted(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.isEmpty ? ">" : "> \(line)"
        }
    }

    /// A line telling repeated phrases apart, or nil when the quote is unique.
    private static func disambiguation(for mark: Mark, in document: ReviewDocument) -> String? {
        let quote = mark.anchor.quote
        guard !quote.isEmpty, let scope = document.scope(for: mark.anchor) else { return nil }

        // PDF selections and page text can differ in line breaks, so compare
        // both with whitespace collapsed.
        let needle = document.isPDF ? quote.collapsingWhitespace() : quote
        let haystack = document.isPDF ? scope.collapsingWhitespace() : scope
        var offset = mark.anchor.span.start
        if document.isPDF {
            offset = scope.nearestSlice(0, min(offset, scope.utf16Length)).collapsingWhitespace().utf16Length
        }
        guard let found = AnchorResolver.occurrence(of: needle, near: offset, in: haystack), found.total > 1 else {
            return nil
        }

        let place = document.isPDF ? "on this page" : "in the document"
        var line = "Which one: occurrence \(found.index) of \(found.total) \(place)"
        let before = mark.anchor.prefix.collapsingWhitespace().trimmingCharacters(in: .whitespaces)
        if !before.isEmpty {
            // The prefix is cut at a fixed length unless it reaches the start of the text.
            let cut = mark.anchor.span.start > mark.anchor.prefix.utf16Length
            line += ", right after \"\(cut ? "…" : "")\(before)\""
        }
        return line
    }

    // MARK: - Insert context

    private static let contextLimit = 80

    /// The text an insertion goes after, or before when it starts a line.
    private static func insertionContext(for mark: Mark, in document: ReviewDocument) -> (relation: String, text: String)? {
        var before = mark.anchor.prefix
        var after = mark.anchor.suffix
        if let scope = document.scope(for: mark.anchor), mark.anchor.span.start <= scope.utf16Length {
            let offset = mark.anchor.span.start
            before = scope.nearestSlice(max(0, offset - contextLimit * 2), offset)
            after = scope.nearestSlice(offset, min(scope.utf16Length, offset + contextLimit * 2))
        }
        if document.isPDF {
            // Page text breaks lines wherever the layout does.
            before = before.collapsingWhitespace()
            after = after.collapsingWhitespace()
        }

        let lineBefore = before.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let lineAfter = after.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""

        let preceding = lineBefore.trimmingCharacters(in: .whitespaces)
        if !preceding.isEmpty {
            return ("after", preceding.count > contextLimit ? "…" + preceding.suffix(contextLimit).droppingFirstWord() : preceding)
        }
        let following = lineAfter.trimmingCharacters(in: .whitespaces)
        if !following.isEmpty {
            return ("before", following.count > contextLimit ? following.prefix(contextLimit).droppingLastWord() + "…" : following)
        }
        return nil
    }
}

extension StringProtocol {
    /// Runs of whitespace and line breaks become one space.
    func collapsingWhitespace() -> String {
        var result = ""
        var pendingSpace = false
        for character in self {
            if character.isWhitespace {
                pendingSpace = true
            } else {
                if pendingSpace { result.append(" ") }
                pendingSpace = false
                result.append(character)
            }
        }
        if pendingSpace { result.append(" ") }
        return result
    }

    /// Drops a leading partial word, as left by cutting text at a fixed length.
    fileprivate func droppingFirstWord() -> String {
        guard let space = firstIndex(of: " ") else { return String(self) }
        return String(self[index(after: space)...])
    }

    fileprivate func droppingLastWord() -> String {
        guard let space = lastIndex(of: " ") else { return String(self) }
        return String(self[..<space])
    }
}
