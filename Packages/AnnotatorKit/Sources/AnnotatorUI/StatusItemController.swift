import AppKit

/// The menu-bar icon and its menu. An `NSStatusItem` rather than SwiftUI's
/// `MenuBarExtra`, because the icon has to accept dropped files.
@MainActor
final class StatusItemController: NSObject {
    private let item: NSStatusItem
    private let reviewClipboard: () -> Void

    init(reviewClipboard: @escaping () -> Void) {
        self.reviewClipboard = reviewClipboard
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "pencil.and.scribble", accessibilityDescription: "Annotator")
                ?? NSImage(systemSymbolName: "pencil.line", accessibilityDescription: "Annotator")
            button.toolTip = "Annotator"
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Review Clipboard Text", action: #selector(reviewClipboardText), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Annotator", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    @objc private func reviewClipboardText() {
        reviewClipboard()
    }
}

/// A menu-bar app shows no menu bar of its own, but text fields only get
/// copy, paste, undo and select-all through the Edit menu's key equivalents.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Quit Annotator", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, title: "Annotator"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "Edit"))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu(window, title: "Window"))

        return main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
