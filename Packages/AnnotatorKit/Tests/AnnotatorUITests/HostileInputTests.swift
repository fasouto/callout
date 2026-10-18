import AnnotatorCore
import AppKit
import Testing
@testable import AnnotatorUI

/// Text nobody writes on purpose but a tool can still be handed: nesting a
/// parser recurses into, documents of a few megabytes, control characters,
/// stacks of combining marks. Each must open as a page, one character for one.
@MainActor
@Suite("Hostile input")
struct HostileInputTests {
    nonisolated private static let cases: [(String, String)] = [
        ("2000 nested quotations", String(repeating: "> ", count: 2000) + "deep"),
        ("100000 nested quotations", String(repeating: "> ", count: 100_000) + "deep"),
        ("100000 nested ordered lists", String(repeating: "1. ", count: 100_000) + "deep"),
        ("50000 nested emphases", (0..<50_000).map { $0 % 2 == 0 ? "*a " : "_b " }.joined() + "x"
            + (0..<50_000).reversed().map { $0 % 2 == 0 ? " a*" : " b_" }.joined()),
        ("2000 nested list items",(0..<2000).map { String(repeating: "  ", count: $0) + "- item \($0)" }.joined(separator: "\n")),
        ("5000 stars around a letter", String(repeating: "*", count: 5000) + "x" + String(repeating: "*", count: 5000)),
        ("50000 open brackets", String(repeating: "[", count: 50000) + "a"),
        ("50000 backticks in runs", (0..<5000).map { String(repeating: "`", count: $0 % 7 + 1) + "a" }.joined()),
        ("one line of 200000 characters", String(repeating: "word ", count: 40000)),
        ("20000 short paragraphs", (0..<20000).map { "Paragraph \($0) says something." }.joined(separator: "\n\n")),
        ("a table of 2000 rows, 30 columns",
         (["|" + (0..<30).map { " c\($0) |" }.joined(), "|" + String(repeating: "---|", count: 30)]
          + (0..<2000).map { row in "|" + (0..<30).map { " r\(row)c\($0) |" }.joined() }).joined(separator: "\n")),
        ("control characters", "Bell \u{7} null \u{0} escape \u{1B}[31mred\u{1B}[0m vertical \u{B} form \u{C} delete \u{7F} end."),
        ("combining marks", String(repeating: "e\u{301}\u{302}\u{303}\u{304}\u{305}", count: 2000) + " after"),
        ("joined emoji at every word", String(repeating: "👩🏽‍💻 🏳️‍🌈 🇪🇸 ", count: 3000)),
        ("only blank lines", String(repeating: "\n", count: 10000)),
        ("carriage returns only", "First line\rsecond line\r\rNew paragraph\r- a list?\r- maybe"),
        ("mixed line endings", "Unix\nWindows\r\nOld Mac\rEnd\r\n\r\n# Heading\r\nText"),
        ("an unclosed fence of 10000 lines", "```\n" + (0..<10000).map { "line \($0)" }.joined(separator: "\n")),
        ("a byte order mark first", "\u{FEFF}# Title\n\nText."),
        ("nothing but link definitions", "[a]: https://example.com\n[b]: https://example.org \"title\""),
        ("footnotes only", "[^1]: A note.\n[^2]: Another."),
        ("a huge HTML block", "<div>\n" + String(repeating: "<p>html</p>\n", count: 5000) + "</div>"),
        ("tabs everywhere", "-\tTabbed item\n\t-\tnested\n\n\tcode by tab\n\nText\twith\ttabs"),
        ("right to left with marks", "\u{202E}reversed\u{202C} and \u{200F}rtl mark\u{200E} and العربية in a line."),
        ("isolated surrogate-like escapes", "&#xD800; &#0; &#x110000; &#99999999;"),
    ]

    @Test(arguments: cases.indices)
    func opensAsAPage(_ index: Int) throws {
        let (name, text) = Self.cases[index]
        for format in [TextFormat.markdown, .plain] {
            let clock = ContinuousClock()
            var session: ReviewSession!
            var page: NSAttributedString!
            let elapsed = clock.measure {
                session = ReviewSession(request: ReviewRequest(
                    content: .text(text, format: format), origin: .agentRequest, reply: .stdout, modes: [.feedback]
                ))
                page = TextStyler.attributedString(layout: session.layout, marks: [], selectedMarkID: nil)
            }
            print("hostile: \(name) (\(format)): \(text.utf16.count) units in, \(page.length) out, \(elapsed)")
            #expect(page.length == session.layout.text.utf16.count, "\(name), \(format)")
            #expect(elapsed < .seconds(10), "\(name), \(format) took \(elapsed)")
        }
    }
}
