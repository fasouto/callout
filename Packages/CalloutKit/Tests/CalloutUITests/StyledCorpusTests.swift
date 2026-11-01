import CalloutCore
import AppKit
import Foundation
import Testing
@testable import CalloutUI

extension OnTheMainThread {
    /// The page against real text rather than sentences written for a test.
    ///
    ///     CALLOUT_CORPUS=~/.claude/projects/<project>/<session>.jsonl swift test --filter StyledCorpusTests
    ///
    /// Sets every text in a Claude Code transcript as a page, replies and what
    /// tools printed alike, as Markdown and as plain text. The page may dress the
    /// text, but one character for one: a selection must still count the same.
    @MainActor
    @Suite("Real pages")
    struct StyledCorpusTests {
        @Test func everyRealTextIsSetOneCharacterForOne() throws {
            guard let path = ProcessInfo.processInfo.environment["CALLOUT_CORPUS"] else { return }
            let lines = try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8).split(separator: "\n")

            var texts: [String] = []
            for line in lines {
                guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let message = entry["message"] as? [String: Any],
                      let blocks = message["content"] as? [[String: Any]] else { continue }
                for block in blocks {
                    if let text = block["text"] as? String, !text.isEmpty { texts.append(text) }
                    // What a tool printed is as wild as text gets.
                    if let printed = block["content"] as? String, !printed.isEmpty, printed.count < 20000 { texts.append(printed) }
                }
            }

            for text in texts {
                for format in [TextFormat.markdown, .plain] {
                    let session = ReviewSession(request: ReviewRequest(
                        content: .text(text, format: format), origin: .lastReply, reply: .stdout, modes: [.feedback]
                    ))
                    let page = TextStyler.attributedString(layout: session.layout, marks: [], selectedMarkID: nil)
                    #expect(page.length == session.layout.text.utf16.count, "\(format): \(text.prefix(60))")
                }
            }
            print("Set \(texts.count) texts from \((path as NSString).lastPathComponent) as pages, twice each.")
        }
    }
}
