import AnnotatorCore
import AppKit
import SwiftUI
import Testing
@testable import AnnotatorUI

/// The tables Claude often writes, at the widest page and the narrowest. Set
/// `ANNOTATOR_SNAPSHOT_DIR` to also write them as PNGs.
@MainActor
@Suite("Tables on the page")
struct TableGalleryTests {
    static let source = """
    Three rounds of fixes, and what each did:

    | Round | What changed | Values normalized | Failed to normalize | Agreement with GSMArena |
    |---|---|---|---|---|
    | 1 | first prompt | 488 | 93 | 84% |
    | 2 | prompt and page-text fixes | 914 | 34 | 96.5% |
    | 3 | per-camera rule | 918 | 30 | 98.3% |

    Of the last three disagreements, two are real differences on the page.

    | | Annotator | Plannotator |
    |---|---|---|
    | Platform | macOS only, native | Browser, any OS |
    | Marks | Delete, replace, insert, comment, keep | Comment, delete, replace |
    | Licence | GPLv3 | MIT / Apache |

    | File | Change |
    |---|---|
    | `Sources/AnnotatorUI/TextStyler.swift` | Tables get their columns from the widest cell, and the header wraps. |
    | `Sources/AnnotatorCore/MarkdownRenderer.swift` | Decides between columns and one cell a line. |

    | Model | Input ($/M) | Output ($/M) | Context |
    |---|---:|---:|---:|
    | Opus 5.5 | 15.00 | 75.00 | 1M |
    | Sonnet 5.5 | 3.00 | 15.00 | 1M |
    | Haiku 4.5 | 1.00 | 5.00 | 200K |

    | Topic | Finding | What it means for us |
    |---|---|---|
    | Plan hook input | `PermissionRequest` matches on tool name, and Claude Code passes the plan as Markdown. | The hook can hand the plan to the app as it is. |
    | Hook timeout | Seconds, default 600 for command hooks, with no documented maximum. | A review can take as long as it needs. |

    The end.
    """

    /// Every line of every table is on the page: none starts or runs past its right edge.
    @Test(arguments: [1040, 720])
    func everyTableFitsThePage(width: Int) throws {
        _ = NSApplication.shared
        let session = ReviewSession(request: ReviewRequest(
            content: .text(Self.source, format: .markdown), origin: .lastReply,
            metadata: ReviewMetadata(title: "Tables"), reply: .clipboard, modes: [.feedback]
        ))
        session.announce = { _ in }
        let window = SnapshotWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 1500), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: ReviewView(session: session) { _ in })
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let textView = try #require(window.contentView.flatMap(Self.textView(in:)))
        let manager = try #require(textView.textLayoutManager)
        let edge = textView.bounds.width + 0.5
        var tableLines = 0
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
            guard let paragraph = fragment.textElement as? NSTextParagraph,
                  paragraph.attributedString.string.contains("\t") else { return true }
            for line in fragment.textLineFragments {
                tableLines += 1
                let right = fragment.layoutFragmentFrame.minX + line.typographicBounds.maxX
                let shown = (line.attributedString.string as NSString).substring(with: line.characterRange)
                #expect(right <= edge, "\(shown.debugDescription) ends at \(right), past the page's edge at \(edge)")
            }
            return true
        }
        #expect(tableLines > 20)

        guard let directory = ProcessInfo.processInfo.environment["ANNOTATOR_SNAPSHOT_DIR"],
              let view = window.contentView, let bitmap = view.snapshotBitmap() else { return }
        try bitmap.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("tables-\(width).png"))
    }

    /// Resizing the window sets the page again only when a table changes size,
    /// and then as a window that size would have set it from the start.
    @Test func aNarrowerPageSetsOnlyTablesTooWideForIt() {
        let narrow = DisplayLayout(document: MarkdownRenderer.render("| Setting | Default |\n|---|---|\n| RATE_LIMIT | 10 |\n"), marks: [])
        #expect(StyledPage(layout: narrow, marks: [], selectedMarkID: nil, added: []).suits(measure: Theme.minimumMeasure))

        let wide = DisplayLayout(document: MarkdownRenderer.render(Self.source), marks: [])
        let page = StyledPage(layout: wide, marks: [], selectedMarkID: nil, added: [])
        #expect(page.suits(measure: Theme.measure - 10))
        #expect(!page.suits(measure: 420))
        let reset = page.set(for: 420)
        #expect(reset.text == StyledPage(layout: wide, marks: [], selectedMarkID: nil, added: [], measure: 420).text)
        #expect(reset.text.string == page.text.string)
    }

    private static func textView(in view: NSView) -> NSTextView? {
        if let textView = view as? AnnotationTextView { return textView }
        for subview in view.subviews {
            if let found = textView(in: subview) { return found }
        }
        return nil
    }
}
