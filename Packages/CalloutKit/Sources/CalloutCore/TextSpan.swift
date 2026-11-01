import Foundation

/// A half-open range of UTF-16 offsets into a text. UTF-16 is used because it is
/// what `NSTextView` and `PDFKit` report for selections.
public struct TextSpan: Codable, Hashable, Sendable, Comparable {
    public var start: Int
    public var end: Int

    public init(_ start: Int, _ end: Int) {
        self.start = start
        self.end = max(start, end)
    }

    public var length: Int { end - start }
    public var isEmpty: Bool { start == end }

    public func overlaps(_ other: TextSpan) -> Bool {
        start < other.end && other.start < end
    }

    public func union(_ other: TextSpan) -> TextSpan {
        TextSpan(min(start, other.start), max(end, other.end))
    }

    public static func < (lhs: TextSpan, rhs: TextSpan) -> Bool {
        (lhs.start, lhs.end) < (rhs.start, rhs.end)
    }
}

extension String {
    var utf16Length: Int { utf16.count }

    /// The text covered by `span`, or nil when the span is out of bounds or
    /// would split a Unicode scalar.
    public func slice(_ span: TextSpan) -> String? {
        guard span.start >= 0, span.start <= span.end, span.end <= utf16.count else { return nil }
        let lower = String.Index(utf16Offset: span.start, in: self)
        let upper = String.Index(utf16Offset: span.end, in: self)
        guard lower.samePosition(in: unicodeScalars) != nil,
              upper.samePosition(in: unicodeScalars) != nil else { return nil }
        return String(unicodeScalars[lower..<upper])
    }

    /// UTF-16 offsets of every occurrence of `needle`, overlapping ones included.
    func occurrences(of needle: String) -> [Int] {
        guard !needle.isEmpty else { return [] }
        let haystack = self as NSString
        var result: [Int] = []
        var from = 0
        while from <= haystack.length {
            let found = haystack.range(
                of: needle,
                options: .literal,
                range: NSRange(location: from, length: haystack.length - from)
            )
            if found.location == NSNotFound { break }
            result.append(found.location)
            from = found.location + 1
        }
        return result
    }
}
