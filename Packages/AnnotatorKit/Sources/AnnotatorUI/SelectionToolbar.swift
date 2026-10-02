import AnnotatorCore
import AppKit
import SwiftUI

/// The small bar of mark buttons that floats above a selection. A child panel
/// that never becomes key, so the keyboard stays with the document.
@MainActor
final class SelectionToolbar {
    private let perform: (MarkKind) -> Void
    private var panel: NSPanel?

    init(perform: @escaping (MarkKind) -> Void) {
        self.perform = perform
    }

    func show(above rect: NSRect, in view: NSView) {
        guard let window = view.window else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let selection = window.convertToScreen(view.convert(rect, to: nil))
        let size = panel.frame.size
        var origin = NSPoint(x: selection.midX - size.width / 2, y: selection.maxY + 6)
        // Stay inside the review window; drop below the selection when there is no room above.
        origin.x = min(max(origin.x, window.frame.minX + 8), window.frame.maxX - size.width - 8)
        if origin.y + size.height > window.frame.maxY - 30 {
            origin.y = selection.minY - size.height - 6
        }
        panel.setFrameOrigin(origin)

        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func makeContentView() -> NSView {
        FirstMouseHostingView(rootView: SelectionToolbarView(perform: perform))
    }

    private func makePanel() -> NSPanel {
        let host = makeContentView()
        let size = host.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        return panel
    }
}

/// Lets the first click on the toolbar press a button instead of only focusing the panel.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct SelectionToolbarView: View {
    let perform: (MarkKind) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MarkKind.allCases, id: \.self) { kind in
                Button {
                    perform(kind)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(kind.tint)
                        KeyCap(kind.key)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(kind.hint) (\(kind.key))")
                .accessibilityLabel(kind.label)
            }
        }
        .padding(.horizontal, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.6)))
        .fixedSize()
    }
}
