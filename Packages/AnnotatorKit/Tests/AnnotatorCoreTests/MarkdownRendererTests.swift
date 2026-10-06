import Foundation
import Testing
@testable import AnnotatorCore

@Suite("Markdown rendering and source mapping")
struct MarkdownRendererTests {
    /// The source text behind a displayed phrase, as a selection of it would map.
    private func sourceText(
        behind phrase: String, in document: RenderedDocument, occurrence: Int = 1
    ) -> String? {
        let displayed = span(of: phrase, in: document.text, occurrence: occurrence)
        guard let source = document.sourceSpan(forDisplayed: displayed.start..<displayed.end) else { return nil }
        return document.source.slice(source)
    }

    private func sourceSpan(
        behind phrase: String, in document: RenderedDocument, occurrence: Int = 1
    ) -> TextSpan? {
        let displayed = span(of: phrase, in: document.text, occurrence: occurrence)
        return document.sourceSpan(forDisplayed: displayed.start..<displayed.end)
    }

    /// Every segment that claims a one-to-one mapping really is the source text.
    private func expectFaithfulMapping(_ document: RenderedDocument, sourceLocation: SourceLocation = #_sourceLocation) {
        for segment in document.segments where segment.isExact {
            let slice = document.source.slice(segment.source!)
            let isLineBreak = slice == "\n" && (segment.text == " " || segment.text == "\n")
            #expect(slice == segment.text || isLineBreak, "segment \(segment.text.debugDescription)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Text and inline styles

    @Test func plainParagraphMapsOneToOne() {
        let document = MarkdownRenderer.render("Hello world")
        #expect(document.text == "Hello world")
        #expect(sourceSpan(behind: "world", in: document) == TextSpan(6, 11))
    }

    @Test func aWordMapsToItselfWhateverPunctuationIsAround() {
        // The parser must not rewrite quotes, dashes or dots: text that no
        // longer matches the source maps only as a whole, and a selected word
        // would then stand for its whole paragraph.
        let sources = [
            "What's actually slow is this conversation. It's very long by now.",
            "She said \"it is slow\" and left -- quickly... then came back.",
            "- **Bold start.** It doesn't run on normal turns, and that's fine.",
        ]
        for source in sources {
            let document = MarkdownRenderer.render(source)
            expectFaithfulMapping(document)
            #expect(document.segments.allSatisfy { $0.source == nil || $0.isExact }, "every run of \(source.debugDescription) maps one to one")
            for word in ["slow", "normal", "quickly"] where source.contains(word) {
                #expect(sourceSpan(behind: word, in: document) == span(of: word, in: source), "\(word) in \(source.debugDescription)")
            }
        }
    }

    @Test func inlineStylesAreHiddenButMapped() {
        let source = "This is **very important** and *subtle* with `code` and ~~old~~ text."
        let document = MarkdownRenderer.render(source)
        #expect(document.text == "This is very important and subtle with code and old text.")
        expectFaithfulMapping(document)

        let bold = document.segments.first { $0.text == "very important" }
        #expect(bold?.style.bold == true)
        #expect(document.segments.first { $0.text == "subtle" }?.style.italic == true)
        #expect(document.segments.first { $0.text == "code" }?.style.code == true)
        #expect(document.segments.first { $0.text == "old" }?.style.strikethrough == true)
    }

    @Test func selectingAWholeStyledRunTakesItsDelimiters() {
        let source = "This is **very important** and *subtle* with `code` and ~~old~~ text."
        let document = MarkdownRenderer.render(source)
        #expect(sourceText(behind: "very important", in: document) == "**very important**")
        #expect(sourceText(behind: "subtle", in: document) == "*subtle*")
        #expect(sourceText(behind: "code", in: document) == "`code`")
        #expect(sourceText(behind: "old", in: document) == "~~old~~")
        #expect(sourceText(behind: "is very important and", in: document) == "is **very important** and")
    }

    @Test func selectingPartOfAStyledRunStaysInside() {
        let document = MarkdownRenderer.render("This is **very important** text.")
        #expect(sourceText(behind: "important", in: document) == "important")
        #expect(sourceText(behind: "very", in: document) == "very")
        #expect(sourceText(behind: "is very", in: document) == "is **very")
    }

    @Test func nestedEmphasisTakesAllDelimiters() {
        let document = MarkdownRenderer.render("A ***strong and emphasised*** phrase and **bold with *nested* part**.")
        #expect(document.text == "A strong and emphasised phrase and bold with nested part.")
        #expect(sourceText(behind: "strong and emphasised", in: document) == "***strong and emphasised***")
        #expect(sourceText(behind: "nested", in: document) == "*nested*")
        #expect(sourceText(behind: "bold with nested part", in: document) == "**bold with *nested* part**")
    }

    @Test func textBetweenTwoStyledRunsDoesNotTakeTheirDelimiters() {
        let document = MarkdownRenderer.render("**a** and **b**")
        #expect(sourceText(behind: " and ", in: document) == " and ")
    }

    @Test func underscoreAndDoubleBacktickDelimiters() {
        let document = MarkdownRenderer.render("An __underlined__ word, _soft_ one and ``a `tick` inside``.")
        #expect(document.text == "An underlined word, soft one and a `tick` inside.")
        #expect(sourceText(behind: "underlined", in: document) == "__underlined__")
        #expect(sourceText(behind: "soft", in: document) == "_soft_")
        #expect(sourceText(behind: "a `tick` inside", in: document) == "``a `tick` inside``")
    }

    @Test func linksShowTheirTextAndSkipTheDestination() {
        let source = "See [the docs](https://example.com/docs) for docs."
        let document = MarkdownRenderer.render(source)
        #expect(document.text == "See the docs for docs.")
        expectFaithfulMapping(document)
        #expect(document.segments.first { $0.text == "the docs" }?.style.link == "https://example.com/docs")
        #expect(sourceText(behind: "the docs", in: document) == "the docs")
        // The last "docs" is the one after the link, not the one inside the URL.
        #expect(sourceSpan(behind: "docs", in: document, occurrence: 2) == span(of: "docs", in: source, occurrence: 3))
    }

    @Test func escapesMapAsWholeUnits() {
        let source = #"A \* star, a \_ line and 2 \< 3."#
        let document = MarkdownRenderer.render(source)
        #expect(document.text == "A * star, a _ line and 2 < 3.")
        #expect(sourceText(behind: "star", in: document) == "star")
        #expect(sourceText(behind: "* star", in: document) == #"\* star"#)
        #expect(sourceText(behind: "2 < 3", in: document) == #"2 \< 3"#)
    }

    @Test func entitiesMapAsWholeUnits() {
        let source = "Fish &amp; chips &copy; 2026"
        let document = MarkdownRenderer.render(source)
        #expect(document.text == "Fish & chips © 2026")
        #expect(sourceText(behind: "& chips", in: document) == "&amp; chips")
        #expect(sourceText(behind: "chips", in: document) == "chips")
        #expect(sourceText(behind: "© 2026", in: document) == "&copy; 2026")
    }

    @Test func ampersandsThatAreNotEntitiesMapOneToOne() {
        let source = "R&D at AT&T; &nosuchentity; stays"
        let document = MarkdownRenderer.render(source)
        #expect(document.text == source)
        expectFaithfulMapping(document)
        #expect(sourceSpan(behind: "stays", in: document) == span(of: "stays", in: source))
    }

    @Test func softBreakShowsAsASpace() {
        let source = "line one\nline two"
        let document = MarkdownRenderer.render(source)
        #expect(document.text == "line one line two")
        #expect(sourceText(behind: "one line", in: document) == "one\nline")
    }

    @Test func hardBreakShowsAsALineBreak() {
        let document = MarkdownRenderer.render("line one  \nline two")
        #expect(document.text == "line one\nline two")
        #expect(sourceText(behind: "two", in: document) == "two")
    }

    @Test func offsetsAreUTF16AfterNonASCIIText() {
        let source = "Café ☕️ **naïve** 🚀 fin — *último* 👩‍💻 fin"
        let document = MarkdownRenderer.render(source)
        #expect(document.text == "Café ☕️ naïve 🚀 fin — último 👩‍💻 fin")
        expectFaithfulMapping(document)
        #expect(sourceText(behind: "naïve", in: document) == "**naïve**")
        #expect(sourceText(behind: "último", in: document) == "*último*")
        #expect(sourceSpan(behind: "fin", in: document, occurrence: 2) == span(of: "fin", in: source, occurrence: 2))
    }

    @Test func repeatedPhrasesMapToTheirOwnOccurrence() {
        let source = "- the plan\n- **the** plan\n- the plan again\n"
        let document = MarkdownRenderer.render(source)
        #expect(sourceSpan(behind: "plan", in: document, occurrence: 1) == span(of: "plan", in: source, occurrence: 1))
        #expect(sourceSpan(behind: "plan", in: document, occurrence: 2) == span(of: "plan", in: source, occurrence: 2))
        #expect(sourceSpan(behind: "plan", in: document, occurrence: 3) == span(of: "plan", in: source, occurrence: 3))
        #expect(sourceSpan(behind: "the", in: document, occurrence: 3) == span(of: "the", in: source, occurrence: 3))
    }

    // MARK: Blocks

    @Test func headingsAndParagraphs() {
        let document = MarkdownRenderer.render("# Title\n\nBody text.\n\n## Section\n")
        #expect(document.text == "Title\nBody text.\nSection")
        #expect(document.segments.first { $0.text == "Title" }?.style.block == .heading(1))
        #expect(document.segments.first { $0.text == "Section" }?.style.block == .heading(2))
        #expect(sourceText(behind: "Section", in: document) == "Section")
    }

    @Test func listsGetMarkersThatAreNotPartOfTheSource() {
        let source = "- alpha\n- beta\n  - nested\n\n3. three\n4. four\n\n- [ ] todo\n- [x] done\n"
        let document = MarkdownRenderer.render(source)
        #expect(document.text == "• alpha\n• beta\n• nested\n3. three\n4. four\n☐ todo\n☑ done")
        expectFaithfulMapping(document)

        #expect(sourceText(behind: "beta", in: document) == "beta")
        #expect(document.segments.first { $0.text == "nested" }?.style.listDepth == 2)
        #expect(document.segments.first { $0.text == "• " }?.style.isListMarker == true)
        #expect(sourceText(behind: "done", in: document) == "done")

        // A selection that runs over a marker maps to the source between the two items.
        #expect(sourceText(behind: "alpha\n• beta", in: document) == "alpha\n- beta")
        // A marker alone has no source.
        let marker = span(of: "• ", in: document.text)
        #expect(document.sourceSpan(forDisplayed: marker.start..<marker.end) == nil)
    }

    @Test func blockQuotesAndNestedContent() {
        let source = "> quoted **text**\n> more\n>\n> - item in quote\n"
        let document = MarkdownRenderer.render(source)
        #expect(document.text == "quoted text more\n• item in quote")
        expectFaithfulMapping(document)
        #expect(document.segments.first { $0.text == "quoted " }?.style.quoteDepth == 1)
        #expect(sourceText(behind: "more", in: document) == "more")
        #expect(sourceText(behind: "item in quote", in: document) == "item in quote")
    }

    @Test func fencedCodeMapsToItsLines() {
        let source = "Before.\n\n```swift\nlet x = 1\nlet y = 2\n```\n\nAfter.\n"
        let document = MarkdownRenderer.render(source)
        #expect(document.text == "Before.\nlet x = 1\nlet y = 2\nAfter.")
        expectFaithfulMapping(document)
        #expect(document.segments.first { $0.text.hasPrefix("let x") }?.style.block == .codeBlock(language: "swift"))
        #expect(sourceText(behind: "y = 2", in: document) == "y = 2")
        #expect(sourceSpan(behind: "After", in: document) == span(of: "After", in: source))
    }

    @Test func codeThatRepeatsItsInfoStringMapsToTheCode() {
        let source = "```swift\nswift\n```\n"
        let document = MarkdownRenderer.render(source)
        #expect(document.text == "swift")
        #expect(sourceSpan(behind: "swift", in: document) == span(of: "swift", in: source, occurrence: 2))
    }

    @Test func indentedCodeInAListMapsLineByLine() {
        let source = "- item\n\n  ```\n  first\n  second\n  ```\n"
        let document = MarkdownRenderer.render(source)
        #expect(document.text == "• item\nfirst\nsecond")
        expectFaithfulMapping(document)
        #expect(sourceSpan(behind: "second", in: document) == span(of: "second", in: source))
    }

    @Test func tablesAreLaidOutInColumns() {
        let source = "Intro.\n\n| Name | Role |\n|---|---|\n| Ada | **Lead** engineer |\n| Bo | Designer |\n\nOutro.\n"
        let document = MarkdownRenderer.render(source)
        #expect(document.text == "Intro.\nName\tRole\nAda\tLead engineer\nBo\tDesigner\nOutro.")
        expectFaithfulMapping(document)

        let header = document.segments.first { $0.text == "Name" }
        #expect(header?.style.block == .tableRow(header: true))
        #expect(header?.style.bold == true)
        #expect(header?.style.tableColumn == 0)
        let cell = document.segments.first { $0.text == " engineer" }
        #expect(cell?.style.block == .tableRow(header: false))
        #expect(cell?.style.tableColumn == 1)
        // The tab between cells is not part of the source.
        #expect(document.segments.first { $0.text == "\t" }?.source == nil)

        #expect(sourceSpan(behind: "Designer", in: document) == span(of: "Designer", in: source))
        #expect(sourceText(behind: "Lead", in: document) == "**Lead**")
        #expect(sourceSpan(behind: "Outro", in: document) == span(of: "Outro", in: source))
    }

    @Test func equalCellsMapToTheirOwnPlace() {
        let source = "| Key | Old | New |\n|---|---|---|\n| a | yes | yes |\n| b | yes | no |\n"
        let document = MarkdownRenderer.render(source)
        #expect(document.text == "Key\tOld\tNew\na\tyes\tyes\nb\tyes\tno")
        for occurrence in 1...3 {
            #expect(sourceSpan(behind: "yes", in: document, occurrence: occurrence) == span(of: "yes", in: source, occurrence: occurrence))
        }
    }

    @Test func emptyCellsKeepTheirColumn() {
        let source = "| A | B | C |\n|---|---|---|\n| 1 |  | 3 |\n"
        let document = MarkdownRenderer.render(source)
        #expect(document.text == "A\tB\tC\n1\t\t3")
        #expect(document.segments.first { $0.text == "3" }?.style.tableColumn == 2)
    }

    @Test func aLongLastColumnStillFits() {
        let long = "A much longer explanation that will need to wrap over several lines in the last column."
        let source = "| Topic | Finding |\n|---|---|\n| Hook timeout | \(long) |\n"
        let document = MarkdownRenderer.render(source)
        #expect(document.text == "Topic\tFinding\nHook timeout\t\(long)")
        expectFaithfulMapping(document)
    }

    @Test func tablesTooWideForColumnsShowEachRowCellByCell() throws {
        let wide = "a fairly long cell of text here"
        let source = "Intro.\n\n| One | Two | Three |\n|---|---|---|\n| \(wide) | second **bold** cell | x |\n| r2 | \(wide) | y |\n\nOutro.\n"
        let document = MarkdownRenderer.render(source)
        // One line per cell, each after the name of its column. The header row is not shown on its own.
        #expect(document.text == """
        Intro.
        One\t\(wide)
        Two\tsecond bold cell
        Three\tx
        One\tr2
        Two\t\(wide)
        Three\ty
        Outro.
        """)
        expectFaithfulMapping(document)

        // The names are added text; the cells map to their own place in the source.
        let names = document.segments.filter { $0.style.tableColumn == 0 }
        #expect(names.map(\.text) == ["One", "Two", "Three", "One", "Two", "Three"])
        #expect(names.allSatisfy { $0.source == nil })
        #expect(sourceSpan(behind: wide, in: document) == span(of: wide, in: source))
        #expect(sourceSpan(behind: wide, in: document, occurrence: 2) == span(of: wide, in: source, occurrence: 2))
        #expect(sourceText(behind: "bold", in: document) == "**bold**")
        #expect(sourceSpan(behind: "Outro", in: document) == span(of: "Outro", in: source))

        // A selection from a name into its cell takes only the cell.
        let line = span(of: "Three\tx", in: document.text)
        let cell = span(of: " x |", in: source)
        #expect(document.sourceSpan(forDisplayed: line.start..<line.end) == TextSpan(cell.start + 1, cell.start + 2))

        // The last cell of each row says so, for the line drawn under the row.
        let ends = document.segments.compactMap { segment -> Bool? in
            guard segment.style.tableColumn == 1, case .tableField(let endsRow) = segment.style.block else { return nil }
            return endsRow
        }
        #expect(ends.contains(true) && ends.contains(false))
    }

    @Test func codeInATableCellWithAnEscapedPipeMapsWordByWord() {
        let source = "| What | How |\n|---|---|\n| Review | `echo plan \\| annotator review -` |\n"
        let document = MarkdownRenderer.render(source)
        #expect(document.text.contains("echo plan | annotator review -"))
        expectFaithfulMapping(document)
        #expect(sourceSpan(behind: "annotator", in: document) == span(of: "annotator", in: source))
        // The pipe stands for its escape as a whole.
        #expect(sourceText(behind: "|", in: document) == "\\|")
    }

    @Test func tablesWithNothingUnderTheirNamesAreShownAsWritten() {
        let wide = "a fairly long name for a column"
        let source = "| \(wide) | \(wide) | x |\n|---|---|---|\n"
        let document = MarkdownRenderer.render(source)
        #expect(document.text == "| \(wide) | \(wide) | x |\n|---|---|---|")
        #expect(document.segments.first?.style.block == .table)
        expectFaithfulMapping(document)
    }

    @Test func thematicBreakAndImage() {
        let document = MarkdownRenderer.render("Above\n\n---\n\n![a chart](chart.png) below\n")
        #expect(document.text == "Above\n———\n[image: a chart] below")
        #expect(sourceText(behind: "[image: a chart]", in: document) == "![a chart](chart.png)")
        #expect(sourceText(behind: "below", in: document) == "below")
    }

    @Test func plainFormatIsNotParsed() {
        let source = "# not a heading\n**not bold**"
        let document = MarkdownRenderer.render(source, format: .plain)
        #expect(document.text == source)
        #expect(sourceText(behind: "**not bold**", in: document) == "**not bold**")
    }

    @Test func emptySourceRendersNothing() {
        #expect(MarkdownRenderer.render("").text == "")
        #expect(MarkdownRenderer.render("", format: .plain).segments.isEmpty)
    }

    // MARK: Carets and drawing

    @Test func caretMapsToTheEndOfTheTextBeforeIt() {
        let source = "- alpha\n- **beta** end\n"
        let document = MarkdownRenderer.render(source)

        let afterAlpha = span(of: "alpha", in: document.text).end
        #expect(document.sourceOffset(forDisplayed: afterAlpha) == span(of: "alpha", in: source).end)

        // Right after a bullet there is no text before the caret on that line.
        let beforeBeta = span(of: "beta", in: document.text).start
        #expect(document.sourceOffset(forDisplayed: beforeBeta) == span(of: "beta", in: source).start)

        let afterBeta = span(of: "beta", in: document.text).end
        #expect(document.sourceOffset(forDisplayed: afterBeta) == span(of: "beta", in: source).end)

        #expect(document.sourceOffset(forDisplayed: 0) == span(of: "alpha", in: source).start)
    }

    @Test func sourceSpansMapBackToWhatIsDisplayed() {
        let source = "- alpha\n- **beta** end\n"
        let document = MarkdownRenderer.render(source)

        let beta = span(of: "beta", in: document.text)
        #expect(document.displayedRanges(forSource: span(of: "**beta**", in: source)) == [beta.start..<beta.end])

        // Across two list items the bullet in between is not part of the source.
        let alpha = span(of: "alpha", in: document.text)
        let ranges = document.displayedRanges(forSource: span(of: "alpha\n- **beta**", in: source))
        #expect(ranges == [alpha.start..<alpha.end, beta.start..<beta.end])

        let insertion = span(of: "end", in: source).start
        #expect(document.displayedOffset(forSource: insertion) == span(of: "end", in: document.text).start)
    }

    @Test func selectionRoundTripsThroughAnAnchor() throws {
        let source = "## Plan\n\n1. Add a **cache** layer\n2. Remove the cache later\n"
        let document = MarkdownRenderer.render(source)

        let selected = try #require(sourceSpan(behind: "cache", in: document, occurrence: 2))
        let anchor = try #require(Anchor.make(in: source, span: selected))
        let deletion = Mark(kind: .delete, anchor: anchor)
        #expect(try EditApplier.apply([deletion], to: source) == "## Plan\n\n1. Add a **cache** layer\n2. Remove the later\n")

        let bold = try #require(sourceSpan(behind: "cache", in: document, occurrence: 1))
        let boldDeletion = Mark(kind: .delete, anchor: try #require(Anchor.make(in: source, span: bold)))
        #expect(try EditApplier.apply([boldDeletion], to: source) == "## Plan\n\n1. Add a layer\n2. Remove the cache later\n")
    }

    // MARK: A realistic document

    @Test func aTypicalPlanMapsFaithfully() {
        let source = """
        # Plan: add rate limiting

        ## Context

        The API has **no limits** today, so a single client can exhaust the pool.
        See [the incident report](https://example.com/incidents/42) for details.

        ## Steps

        1. Add a `RateLimiter` middleware in `api/middleware.py`
           - token bucket, *per API key*
           - configurable via `RATE_LIMIT_RPS`
        2. Return `429` with a `Retry-After` header
        3. Tests:
           - [ ] unit tests for the bucket
           - [x] integration test hitting `/health`

        ```python
        class RateLimiter:
            def allow(self, key: str) -> bool:
                return self.bucket(key).take()
        ```

        | Setting | Default |
        |---|---|
        | `RATE_LIMIT_RPS` | 10 |

        > Note: this does not cover websockets & streaming.

        """
        let document = MarkdownRenderer.render(source)
        expectFaithfulMapping(document)

        // Everything the reader sees, except list markers and block breaks, comes from the source.
        for segment in document.segments where segment.source == nil {
            #expect(segment.text == "\n" || segment.text == "\t" || segment.style.isListMarker, "unmapped \(segment.text.debugDescription)")
        }
        for phrase in ["no limits", "the incident report", "RateLimiter", "per API key", "429",
                       "unit tests for the bucket", "return self.bucket(key).take()", "websockets & streaming"] {
            #expect(sourceText(behind: phrase, in: document)?.contains(phrase) == true, "\(phrase)")
        }
        #expect(sourceText(behind: "per API key", in: document) == "*per API key*")
        // The second one is inline code in a table cell: selecting all of it takes its backticks.
        #expect(sourceSpan(behind: "RATE_LIMIT_RPS", in: document, occurrence: 2) == span(of: "`RATE_LIMIT_RPS`", in: source, occurrence: 2))
    }
}
