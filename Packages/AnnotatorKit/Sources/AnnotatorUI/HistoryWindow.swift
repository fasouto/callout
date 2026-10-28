import AnnotatorCore
import AnnotatorStore
import AppKit
import PDFKit
import SwiftUI

@MainActor
final class HistoryWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store: Store?

    init(store: Store?) {
        self.store = store
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
            )
            window.title = "History"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: HistoryView(store: store))
            window.setFrameAutosaveName("HistoryWindow")
            if window.frame.origin == .zero { window.center() }
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

/// Every finished review, as a shelf of marked pages: each card shows the page
/// as it was marked. Selecting one shows what was sent back, beside the shelf.
struct HistoryView: View {
    let store: Store?

    @State private var query = ""
    @State private var reviews: [ReviewSummary] = []
    @State private var selection: UUID?
    @State private var detail: ReviewDetail?
    @State private var copied = false
    @State private var thumbnails = HistoryThumbnails()

    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 210), spacing: 28, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 30) {
                ForEach(reviews) { review in
                    HistoryCard(review: review, thumbnail: thumbnails.image(for: review.id, store: store), isSelected: selection == review.id)
                        .onTapGesture { selection = selection == review.id ? nil : review.id }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAddTraits(selection == review.id ? .isSelected : [])
                }
            }
            .padding(28)
        }
        .background(Color(nsColor: Theme.desk))
        .overlay {
            if reviews.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No reviews yet" : "No review matches",
                    systemImage: query.isEmpty ? "tray" : "magnifyingglass",
                    description: Text(query.isEmpty
                        ? "Reviews you finish are kept here, as the pages you marked. To start one, select text in any app and press \(Hotkey.stored.display), or drop a file on the icon in the menu bar."
                        : "Titles, text, feedback and overall comments are searched.")
                )
            }
        }
        .searchable(text: $query, prompt: "Search reviews")
        .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            if let detail {
                HistoryDetail(detail: detail, copied: $copied) {
                    try? store?.deleteReview(detail.summary.id)
                    selection = nil
                    reload()
                }
                .inspectorColumnWidth(min: 300, ideal: 380, max: 520)
            }
        }
        .frame(minWidth: 680, minHeight: 400)
        .environment(\.locale, .interface)
        .onAppear(perform: reload)
        .onChange(of: query) { reload() }
        .onChange(of: selection) { _, id in
            copied = false
            detail = id.flatMap { try? store?.review($0) }
        }
    }

    private func reload() {
        reviews = (try? store?.history(matching: query)) ?? []
        if let selection, !reviews.contains(where: { $0.id == selection }) { self.selection = nil }
    }
}

/// One review on the shelf: its page, marked, with what it was and when.
private struct HistoryCard: View {
    let review: ReviewSummary
    let thumbnail: NSImage?
    let isSelected: Bool

    private var outcome: String {
        if review.decision == .approve { return "Approved" }
        return review.markCount == 1 ? "1 mark" : "\(review.markCount) marks"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.white
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                }
            }
            .aspectRatio(3 / 4, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if review.decision == .approve {
                    Text("Approved")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color(nsColor: Theme.keep))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: Theme.keep), lineWidth: 1.5))
                        .rotationEffect(.degrees(-8))
                        .padding(10)
                }
            }
            .shadow(color: .black.opacity(0.14), radius: 3, y: 1.5)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(-5)
                    .opacity(isSelected ? 1 : 0)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(review.title)
                    .font(.system(size: 13.5, weight: .semibold, design: .serif))
                    .lineLimit(2)
                Text("\(review.origin.label), \(outcome)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(review.createdAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(review.title). \(review.origin.label), \(outcome)")
    }
}

/// Thumbnails of reviewed pages, drawn once and kept while the window is open.
@MainActor
@Observable
final class HistoryThumbnails {
    @ObservationIgnored private var cache: [UUID: NSImage] = [:]

    func image(for id: UUID, store: Store?) -> NSImage? {
        if let cached = cache[id] { return cached }
        guard let detail = try? store?.review(id), let image = Self.draw(detail) else { return nil }
        cache[id] = image
        return image
    }

    /// The size thumbnails are drawn at, in points: a sheet in proportion.
    static let size = NSSize(width: 240, height: 320)

    /// The page as it was marked: the text with its marks, on white, at under half
    /// of its size. A PDF shows its first page.
    static func draw(_ detail: ReviewDetail) -> NSImage? {
        if let text = detail.contentText {
            let document = MarkdownRenderer.render(text, format: .markdown)
            let layout = DisplayLayout(document: document, marks: detail.marks, removals: [])
            // Drawn without the page's layout, which is what draws pins.
            let styled = TextStyler.attributedString(layout: layout, marks: detail.marks, selectedMarkID: nil, added: [], pins: .wash)
            return NSImage(size: size, flipped: true) { rect in
                // Paper, whatever the appearance.
                NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
                    NSColor.white.setFill()
                    rect.fill()
                    let scale: CGFloat = 0.46
                    let inset: CGFloat = 16
                    NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
                    styled.draw(
                        with: NSRect(x: inset / scale, y: inset / scale, width: (rect.width - 2 * inset) / scale, height: (rect.height - inset) / scale),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                    )
                }
                return true
            }
        }
        if let path = detail.filePath, let page = PDFDocument(url: URL(fileURLWithPath: path))?.page(at: 0) {
            return page.thumbnail(of: size, for: .mediaBox)
        }
        return nil
    }
}

extension Locale {
    /// English words with the user's own conventions for dates and times, so
    /// dates do not switch language in the middle of an English interface.
    static let interface = Locale(identifier: "en_\(Locale.current.region?.identifier ?? "US")")
}

extension ReviewOrigin {
    /// What a review was of, in a word.
    var label: String {
        switch self {
        case .planHook: "Plan"
        case .lastReply: "Reply"
        case .agentRequest: "Document"
        case .hotkey, .service: "Selection"
        case .fileDrop, .share: "File"
        }
    }
}

private struct HistoryDetail: View {
    let detail: ReviewDetail
    @Binding var copied: Bool
    let delete: () -> Void

    /// What went back: the feedback, the corrected text, or just the approval.
    private var output: String {
        detail.feedback ?? detail.editedText ?? "Approved without changes."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.summary.title)
                        .font(.system(size: 20, weight: .bold, design: .serif))
                    Text("\(detail.summary.origin.label), \(detail.summary.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(.interface)))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let project = detail.summary.projectPath {
                        Text(project)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Text(output)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(24)
        }
        .toolbar {
            ToolbarItemGroup {
                Button(copied ? "Copied" : (detail.editedText != nil ? "Copy Text" : "Copy Feedback")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                    copied = true
                }
                Button("Delete", role: .destructive, action: delete)
            }
        }
    }
}
