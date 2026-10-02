import Foundation
import Testing
@testable import AnnotatorCore

@Suite("Terminal cleanup")
struct TerminalCleanupTests {
    @Test func aReplyCopiedFromClaudeCodeReadsAsItWasWritten() {
        // Copied from a terminal 62 columns wide: a bullet in front, two spaces
        // of indentation, and lines broken at the window's edge.
        let raw = """
        ⏺ The plan has three parts. First we add a rate limiter in the
          middleware, then we return 429 with a Retry-After header, and
          finally we cover both with tests.

          Steps:

          1. Add a RateLimiter middleware in api/middleware.py, with a
             token bucket per API key
          2. Return 429
          3. Tests

        """
        let expected = """
        The plan has three parts. First we add a rate limiter in the middleware, then we return 429 with a Retry-After header, and finally we cover both with tests.

        Steps:

        1. Add a RateLimiter middleware in api/middleware.py, with a token bucket per API key
        2. Return 429
        3. Tests
        """
        #expect(TerminalCleanup.clean(raw) == expected)
    }

    @Test func boxesLoseTheirFrame() {
        let raw = """
        ╭──────────────────────────────────────────────╮
        │ Ready to code?                               │
        │                                              │
        │ Here is the plan: add a cache in front of    │
        │ the database and invalidate it on writes.    │
        ╰──────────────────────────────────────────────╯
        """
        #expect(TerminalCleanup.clean(raw) == "Ready to code?\n\nHere is the plan: add a cache in front of the database and invalidate it on writes.")
    }

    @Test func rulesAndElbowsAreRemoved() {
        let raw = """
        ────────────────────────
        ⏺ Updated plan
          ⎿  /plan to preview
        ────────────────────────
        """
        // The elbow's line stays indented under the line it belongs to.
        #expect(TerminalCleanup.clean(raw) == "Updated plan\n   /plan to preview")
    }

    @Test func shortLinesKeepTheirBreaks() {
        let raw = "Dear team,\nThanks for the review.\nBest,\nAda"
        #expect(TerminalCleanup.clean(raw) == raw)
    }

    @Test func linesThatEndedOnPurposeAreNotJoined() {
        // The second line is short, so the third would have fitted: that break was meant.
        let raw = """
        This first line runs all the way to the edge of the terminal window
        and ends here.
        A new sentence on a new line that was written this way on purpose.
        """
        let expected = """
        This first line runs all the way to the edge of the terminal window and ends here.
        A new sentence on a new line that was written this way on purpose.
        """
        #expect(TerminalCleanup.clean(raw) == expected)
    }

    @Test func listsHeadingsQuotesAndTablesStartNewLines() {
        let raw = """
        Here is a paragraph that is long enough to reach the right edge of it
        - a list item right after it
        ## A heading that is also quite long and reaches the right edge of it
        Text after the heading that is long enough to reach the right edge ok
        > a quotation
        | a | table | row that is rather long and reaches the right edge ok |
        | b | another row                                                    |
        """
        let cleaned = TerminalCleanup.clean(raw)
        #expect(cleaned.split(separator: "\n").count == 7)
        #expect(cleaned.contains("\n- a list item right after it\n"))
        #expect(cleaned.contains("\n> a quotation\n"))
    }

    @Test func codeBlocksAreLeftAlone() {
        let raw = """
        Run this command, which is long enough to reach the edge of the window:

        ```sh
        swift build --configuration release --product annotator --verbose
        cd Packages/AnnotatorKit
        ```

        Then the text continues and is again long enough to reach the edge of
        the window.
        """
        let cleaned = TerminalCleanup.clean(raw)
        #expect(cleaned.contains("```sh\nswift build --configuration release --product annotator --verbose\ncd Packages/AnnotatorKit\n```"))
        #expect(cleaned.hasSuffix("reach the edge of the window."))
    }

    @Test func blankLinesAreKeptButNotPiledUp() {
        #expect(TerminalCleanup.clean("\n\n  one\n\n\n\n  two\n\n") == "one\n\ntwo")
        #expect(TerminalCleanup.clean("") == "")
        #expect(TerminalCleanup.clean("   \n  ") == "")
    }

    @Test func trailingSpacesAndWindowsLineEndingsGo() {
        #expect(TerminalCleanup.clean("one   \r\ntwo\t\r\n") == "one\ntwo")
    }

    @Test func terminalsAreRecognisedByBundleIdentifier() {
        #expect(TerminalCleanup.isTerminal(bundleIdentifier: "com.apple.Terminal"))
        #expect(TerminalCleanup.isTerminal(bundleIdentifier: "com.googlecode.iterm2"))
        #expect(TerminalCleanup.isTerminal(bundleIdentifier: "com.mitchellh.ghostty"))
        #expect(!TerminalCleanup.isTerminal(bundleIdentifier: "com.apple.Safari"))
        #expect(!TerminalCleanup.isTerminal(bundleIdentifier: nil))
    }
}
