import AppKit
import Testing
@testable import AnnotatorUI

@MainActor
@Suite("Dock presence")
struct DockPresenceTests {
    /// A window that says it is on screen without being put there.
    private final class Shown: NSWindow {
        override var isVisible: Bool { true }
    }

    private func window<Window: NSWindow>(_ type: Window.Type, _ style: NSWindow.StyleMask) -> Window {
        let window = Window(contentRect: .zero, styleMask: style, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func onlyTitledWindowsOnScreenAreSwitchedTo() {
        _ = NSApplication.shared
        let review = window(Shown.self, [.titled, .closable])
        let selectionBar = window(Shown.self, [.borderless])
        let notShown = window(NSWindow.self, [.titled])

        #expect(DockPresence.hasWindowToSwitchTo([selectionBar, review]))
        // The selection bar and the menu-bar icon's window are not something to switch to.
        #expect(!DockPresence.hasWindowToSwitchTo([selectionBar, notShown]))
        // A window that is closing no longer counts, so the last one closing ends it.
        #expect(!DockPresence.hasWindowToSwitchTo([review], closing: review))
        #expect(DockPresence.hasWindowToSwitchTo([review, window(Shown.self, [.titled])], closing: review))
    }
}
