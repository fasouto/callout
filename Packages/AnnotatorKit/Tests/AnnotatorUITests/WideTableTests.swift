import AnnotatorCore
import AppKit
import SwiftUI
import Testing
@testable import AnnotatorUI

/// Set `ANNOTATOR_SNAPSHOT_DIR` to also write the window as a PNG.
@MainActor
@Suite("Wide tables")
struct WideTableTests {
    private static let source = """
    # What the docs say

    | Topic | Finding | What it means for us |
    |---|---|---|
    | Plan hook input | `PermissionRequest` matches on tool name, and Claude Code passes the plan as Markdown. | The hook can hand the plan to the app as it is. |
    | Hook timeout | Seconds, default 600 for command hooks, with no documented maximum. | A review can take as long as it needs. |
    | Session id | Substituted in skill content and set in the environment of hook subprocesses. | The last reply can be found without guessing. |

    A narrow table still goes in columns:

    | Setting | Default |
    |---|---|
    | RATE_LIMIT_RPS | 10 |
    """

    private func session() -> ReviewSession {
        let session = ReviewSession(request: ReviewRequest(
            content: .text(Self.source, format: .markdown), origin: .planHook,
            metadata: ReviewMetadata(title: "Plan"), reply: .clipboard, modes: [.feedback, .applyEdits]
        ))
        session.announce = { _ in }
        return session
    }

    @Test func aCellOfAWideTableIsMarkedLikeAnyOtherText() throws {
        let session = session()
        let shown = TextStyler.attributedString(layout: session.layout, marks: [], selectedMarkID: nil).string
        #expect(shown.contains("Topic\tPlan hook input\n"))
        #expect(shown.contains("What it means for us\tA review can take as long as it needs.\n"))
        // The narrow table keeps its columns, header row included.
        #expect(shown.contains("Setting\tDefault\n"))
        #expect(!shown.contains("|---|"))

        let range = (Self.source as NSString).range(of: "with no documented maximum")
        session.addMark(.delete, span: TextSpan(range.location, NSMaxRange(range)))
        #expect(session.feedback().contains("> with no documented maximum"))
        // Striking part of a cell leaves the row with its three cells.
        let row = try #require(try session.editedText().split(separator: "\n").first { $0.contains("Hook timeout") })
        #expect(!row.contains("with no documented maximum"))
        #expect(row.hasPrefix("| Hook timeout | Seconds, default 600 for command hooks"))
        #expect(row.filter { $0 == "|" }.count == 4)
    }

    @Test func itLaysOutOnThePage() throws {
        _ = NSApplication.shared
        let session = session()
        let range = (Self.source as NSString).range(of: "as long as it needs")
        session.addMark(.comment, span: TextSpan(range.location, NSMaxRange(range)), note: "Up to the two-hour limit.")
        session.selectedMarkID = nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ReviewView(session: session) { _ in })
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        guard let directory = ProcessInfo.processInfo.environment["ANNOTATOR_SNAPSHOT_DIR"], let view = window.contentView else { return }
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            guard let bitmap = view.snapshotBitmap() else { continue }
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("wide-table-\(suffix).png"))
        }
    }
}
