import AnnotatorCore
import AnnotatorStore
import AppKit
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

/// Every finished review: a searchable list, and what was sent back for the selected one.
struct HistoryView: View {
    let store: Store?

    @State private var query = ""
    @State private var reviews: [ReviewSummary] = []
    @State private var selection: UUID?
    @State private var detail: ReviewDetail?
    @State private var copied = false

    var body: some View {
        NavigationSplitView {
            List(reviews, selection: $selection) { review in
                HistoryRow(review: review)
                    .tag(review.id)
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search reviews")
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
            .overlay {
                if reviews.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "No reviews yet" : "No review matches",
                        systemImage: query.isEmpty ? "tray" : "magnifyingglass",
                        description: Text(query.isEmpty ? "Reviews you finish are kept here." : "Titles, text, feedback and overall comments are searched.")
                    )
                }
            }
        } detail: {
            if let detail {
                HistoryDetail(detail: detail, copied: $copied) {
                    try? store?.deleteReview(detail.summary.id)
                    selection = nil
                    reload()
                }
            } else {
                Text("Select a review")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 680, minHeight: 400)
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

private struct HistoryRow: View {
    let review: ReviewSummary

    private var outcome: String {
        if review.decision == .approve { return "Approved" }
        return review.markCount == 1 ? "1 mark" : "\(review.markCount) marks"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(review.title)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(review.origin.label)
                Text(outcome)
                Spacer(minLength: 4)
                Text(review.createdAt, format: .relative(presentation: .named).locale(.interface))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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
