import Foundation
import Testing
@testable import CalloutCore

/// A check against real text rather than sentences written for a test.
///
///     CALLOUT_CORPUS=~/.claude/projects/<project>/<session>.jsonl swift test --filter CorpusTests
///
/// Renders every reply in a Claude Code transcript and reports each run of
/// text that maps to its source only as a whole: a word selected in such a run
/// would be marked as all of it.
@Suite("Real replies")
struct CorpusTests {
    @Test func everyRunOfARealReplyMapsToItsOwnSource() throws {
        guard let path = ProcessInfo.processInfo.environment["CALLOUT_CORPUS"] else { return }
        let lines = try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8).split(separator: "\n")

        var replies = 0
        var coarse: [String] = []
        for line in lines {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  let message = entry["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks where block["type"] as? String == "text" {
                guard let text = block["text"] as? String, !text.isEmpty else { continue }
                replies += 1
                for segment in MarkdownRenderer.render(text).segments where segment.source != nil && !segment.isExact {
                    // An escaped character or an entity is one character standing for a few,
                    // and an image is shown as its description: those are meant to map whole.
                    if segment.text.utf16.count <= 2 || segment.text.hasPrefix("[image") { continue }
                    coarse.append(segment.text)
                }
            }
        }
        print("corpus: \(replies) replies, \(coarse.count) runs that map only as a whole")
        for run in coarse.prefix(12) { print("  coarse: \(String(run.prefix(100)).debugDescription)") }
        #expect(replies > 0, "the transcript has replies")
        #expect(coarse.isEmpty)
    }
}
