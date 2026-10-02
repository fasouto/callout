import Foundation

/// Finds where an anchor sits in a text: at its recorded span when the quote is
/// still there, otherwise at the occurrence whose surroundings match best.
public enum AnchorResolver {
    public static func resolve(_ anchor: Anchor, in text: String) -> TextSpan? {
        let units = Array(text.utf16)
        // The recorded position only counts when the text around it is unchanged:
        // in a revised text the same offsets can land on another occurrence.
        if text.slice(anchor.span) == anchor.quote {
            let expected = anchor.prefix.utf16Length + anchor.suffix.utf16Length
            if contextScore(of: anchor, at: anchor.span, in: units) == expected { return anchor.span }
        }

        let candidates: [TextSpan]
        if anchor.quote.isEmpty {
            candidates = insertionCandidates(for: anchor, in: text)
        } else {
            let length = anchor.quote.utf16Length
            candidates = text.occurrences(of: anchor.quote).map { TextSpan($0, $0 + length) }
        }

        let best = candidates.max { lhs, rhs in
            let left = contextScore(of: anchor, at: lhs, in: units)
            let right = contextScore(of: anchor, at: rhs, in: units)
            if left != right { return left < right }
            return abs(lhs.start - anchor.span.start) > abs(rhs.start - anchor.span.start)
        }
        guard let best else { return nil }
        if anchor.quote.isEmpty, contextScore(of: anchor, at: best, in: units) == 0 { return nil }
        return best
    }

    /// The 1-based index of the occurrence of `quote` nearest to `offset`, and how many there are.
    static func occurrence(of quote: String, near offset: Int, in text: String) -> (index: Int, total: Int)? {
        let starts = text.occurrences(of: quote)
        guard let nearest = starts.indices.min(by: { abs(starts[$0] - offset) < abs(starts[$1] - offset) }) else {
            return nil
        }
        return (nearest + 1, starts.count)
    }

    private static let probeLength = 12

    private static func insertionCandidates(for anchor: Anchor, in text: String) -> [TextSpan] {
        var offsets = Set<Int>()
        let prefixProbe = String(anchor.prefix.suffix(probeLength))
        for start in text.occurrences(of: prefixProbe) {
            offsets.insert(start + prefixProbe.utf16Length)
        }
        let suffixProbe = String(anchor.suffix.prefix(probeLength))
        for start in text.occurrences(of: suffixProbe) {
            offsets.insert(start)
        }
        return offsets.sorted().map { TextSpan($0, $0) }
    }

    /// How many UTF-16 units of the anchor's prefix and suffix match around `span`.
    private static func contextScore(of anchor: Anchor, at span: TextSpan, in units: [UInt16]) -> Int {
        let prefix = Array(anchor.prefix.utf16)
        let suffix = Array(anchor.suffix.utf16)

        var before = 0
        while before < prefix.count, span.start - before - 1 >= 0,
              units[span.start - before - 1] == prefix[prefix.count - before - 1] {
            before += 1
        }
        var after = 0
        while after < suffix.count, span.end + after < units.count,
              units[span.end + after] == suffix[after] {
            after += 1
        }
        return before + after
    }
}
