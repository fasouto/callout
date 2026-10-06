import AppKit

/// A menu-bar app has no Dock icon, and macOS leaves such apps out of the ⌘Tab
/// switcher. While one of its windows is open Annotator is a regular app, so
/// the window can be switched to like any other; when the last one closes it
/// goes back to being only a menu-bar icon.
@MainActor
final class DockPresence: NSObject {
    func start() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowAppeared), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowAppeared), name: NSWindow.didBecomeMainNotification, object: nil)
        center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
    }

    /// Whether any of the windows is one a person would switch to: a titled
    /// window on screen. The selection bar, toasts and the menu-bar icon's own
    /// window do not count. `closing` is a window on its way out.
    static func hasWindowToSwitchTo(_ windows: [NSWindow], closing: NSWindow? = nil) -> Bool {
        windows.contains { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
    }

    @objc private func windowAppeared() {
        update(closing: nil)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        update(closing: notification.object as? NSWindow)
    }

    private func update(closing: NSWindow?) {
        let policy: NSApplication.ActivationPolicy = Self.hasWindowToSwitchTo(NSApp.windows, closing: closing) ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Becoming a regular app does not by itself bring its menu bar forward.
        if policy == .regular { NSApp.activate(ignoringOtherApps: true) }
    }
}
