import Foundation
import Testing
@testable import AnnotatorCore

/// Markdown as it is really written: punctuation the parser likes to rewrite,
/// accents, emoji, nesting, and syntax inside syntax. Whatever is shown has to
/// map to its own place in the source, or a selected word is marked as more
/// than itself.
@Suite("Awkward Markdown")
struct AwkwardMarkdownTests {
    private static let pieces: [String] = [
        "It's \"quoted\" -- and it's 'single' --- with dots... and (c) or (tm) signs.",
        "El método `añadir()` no falla: ¿por qué? ¡Porque sí! Señor Muñoz, 100 % seguro.",
        "Emoji 🚀 in a sentence, a flag 🇪🇸, a family 👨‍👩‍👧, and text after them.",
        "A line with a hard break  \nand its continuation, then a soft\nbreak in the same paragraph.",
        "Escapes: \\*not emphasis\\*, a \\# that is no heading, 5 \\< 6 and a back\\\\slash.",
        "Entities: fish &amp; chips, 3 &lt; 4, a non&#45;breaking thing and &copy; 2026.",
        "A [link with **bold** text](https://example.com/a_b_c?x=1&y=2) and <https://auto.link/path>.",
        "Nested **bold with *italic inside* it** and ~~struck `code` text~~ in one line.",
        "Snake_case_names and file_name.swift keep their underscores; 2*3*4 keeps its stars.",
        "> A quotation with *emphasis*,\n> on two lines, it's quoted.\n>\n> > And a nested one.",
        "1. First item, it's numbered\n   - nested bullet with `code`\n   - another, with \"quotes\"\n2. Second item\n\n   A paragraph inside the second item.",
        "- [ ] an open task -- not done\n- [x] a done task... finally",
        "Setext heading, it's fine\n=========================\n\nAnd a paragraph under it.",
        "```swift\nlet text = \"it's -- code\" // ... stays as written\n```",
        "    indented code, it's -- kept\n\nAnd text after it.",
        "| Name | What it's for |\n|:--|--:|\n| `a\\|b` | pipes -- and \"quotes\" |\n| plain | it's a cell... |",
        "Text with <span>inline html</span> in it, and a line of html:\n\n<div align=\"center\">centered</div>\n\nThen more.",
        "A footnote-like thing[^1] and a ~single tilde~ and H~2~O and x^2^.\n\n[^1]: The note's text.",
        "Trailing spaces   \t\nand\ttabs\tinside, plus a very long word: Donaudampfschifffahrtsgesellschaftskapitän.",
        "CJK 日本語のテキスト and Arabic مرحبا بالعالم and Hebrew שלום mixed in a line, it's all text.",
        "A horizontal rule follows.\n\n---\n\n***\n\nAnd text after two rules.",
        "An image ![alt, it's text](pic.png \"a title\") in a sentence -- then more.",
        "Line one\\\nline two after a backslash break, it's the same paragraph.",
        "*Emphasis at the very start* and at the very **end**",
        "Curly “quotes” already in the source, an em dash — and an ellipsis … stay as they are.",
    ]

    private static var document: String { pieces.joined(separator: "\n\n") }

    /// Every run that says it maps one to one really is the source at that place.
    private func expectFaithful(_ rendered: RenderedDocument, _ comment: Comment) {
        for segment in rendered.segments where segment.isExact {
            let slice = rendered.source.slice(segment.source!)
            let isLineBreak = slice == "\n" && (segment.text == " " || segment.text == "\n")
            #expect(slice == segment.text || isLineBreak, comment)
        }
    }

    @Test(arguments: pieces.indices)
    func everyWordMapsToItself(_ index: Int) throws {
        let source = Self.pieces[index]
        let rendered = MarkdownRenderer.render(source)
        expectFaithful(rendered, "piece \(index)")

        // Each word of four letters or more that appears once in both the page
        // and the source is selected on the page; it must come back as itself.
        let shown = rendered.text as NSString
        let original = source as NSString
        var checked = 0
        shown.enumerateSubstrings(in: NSRange(location: 0, length: shown.length), options: .byWords) { word, range, _, _ in
            guard let word, word.count >= 4,
                  shown.range(of: word, options: [], range: NSRange(location: NSMaxRange(range), length: shown.length - NSMaxRange(range))).location == NSNotFound,
                  shown.range(of: word).location == range.location else { return }
            let first = original.range(of: word)
            guard first.location != NSNotFound,
                  original.range(of: word, options: [], range: NSRange(location: NSMaxRange(first), length: original.length - NSMaxRange(first))).location == NSNotFound
            else { return }
            // An image is shown as its description and maps as a whole, by design.
            var offset = 0
            let isWhole = rendered.segments.contains { segment in
                defer { offset += segment.text.utf16.count }
                return !segment.isExact && offset <= range.location && NSMaxRange(range) <= offset + segment.text.utf16.count
            }
            guard !isWhole else { return }
            let span = rendered.sourceSpan(forDisplayed: range.location..<NSMaxRange(range))
            // A word that is all of an emphasised or code run takes its delimiters along.
            let marked = span.flatMap { source.slice($0) }?.trimmingCharacters(in: CharacterSet(charactersIn: "*_~`"))
            #expect(marked == word, "\(word.debugDescription) in piece \(index) came back as \(String(describing: span.flatMap { source.slice($0) }))")
            checked += 1
        }
        #expect(checked > 0, "piece \(index) has words to check")
    }

    @Test func theWholeDocumentRendersAndMaps() {
        let rendered = MarkdownRenderer.render(Self.document)
        expectFaithful(rendered, "the whole document")
        // Runs that map only as a whole are single characters standing for an
        // escape or an entity, images, and raw HTML: nothing a word sits in.
        let coarse = rendered.segments.filter { $0.source != nil && !$0.isExact && $0.text.utf16.count > 2 }
            .filter { !$0.text.hasPrefix("[image") }
        #expect(coarse.map(\.text) == [])
    }
}
