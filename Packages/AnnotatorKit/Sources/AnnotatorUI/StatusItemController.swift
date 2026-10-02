import AppKit

/// The menu-bar icon and its menu. An `NSStatusItem` rather than SwiftUI's
/// `MenuBarExtra`, because the icon has to accept dropped files.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate, NSMenuDelegate {
    struct Actions {
        var markUpSelection: () -> Void
        var reviewClipboard: () -> Void
        var openFile: (URL) -> Void
        var showHistory: () -> Void
        var showSettings: () -> Void
    }

    private let item: NSStatusItem
    private let actions: Actions
    private let hotkeyItem = NSMenuItem()

    init(actions: Actions) {
        self.actions = actions
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "pencil.and.scribble", accessibilityDescription: "Annotator")
                ?? NSImage(systemSymbolName: "pencil.line", accessibilityDescription: "Annotator")
            button.toolTip = "Annotator: drop a .md, .txt or .pdf file here to mark it up"
            // The status item's window takes the drop; its delegate gets the dragging calls.
            button.window?.registerForDraggedTypes([.fileURL])
            button.window?.delegate = self
        }

        let menu = NSMenu()
        menu.delegate = self
        hotkeyItem.title = "Mark Up Selection"
        hotkeyItem.action = #selector(markUpSelection)
        hotkeyItem.target = self
        menu.addItem(hotkeyItem)
        menu.addItem(withTitle: "Mark Up Clipboard Text", action: #selector(reviewClipboardText), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "History…", action: #selector(showHistory), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Annotator", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Shown as a reminder of the shortcut; the menu item itself has no key equivalent.
        hotkeyItem.title = "Mark Up Selection (\(Hotkey.stored.display))"
    }

    @objc private func markUpSelection() {
        actions.markUpSelection()
    }

    @objc private func reviewClipboardText() {
        actions.reviewClipboard()
    }

    @objc private func showHistory() {
        actions.showHistory()
    }

    @objc private func showSettings() {
        actions.showSettings()
    }

    // MARK: Files dropped on the icon

    private func droppedFile(_ sender: NSDraggingInfo) -> URL? {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let url = droppedFile(sender), CaptureController.canOpen(url) else { return [] }
        item.button?.highlight(true)
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        item.button?.highlight(false)
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        item.button?.highlight(false)
        guard let url = droppedFile(sender) else { return false }
        actions.openFile(url)
        return true
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
