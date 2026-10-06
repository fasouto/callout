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
            button.image = MenuBarIcon.image()
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
        menu.addItem(withTitle: "About Annotator", action: #selector(showAbout), keyEquivalent: "").target = self
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

    @objc private func showAbout() {
        AboutPanel.show()
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

/// The standard About panel, with a line on what the app is for.
@MainActor
enum AboutPanel {
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Annotator", .credits: credits])
    }

    /// What the panel says under the version.
    static let credits: NSAttributedString = {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.paragraphSpacing = 6
        let text = NSMutableAttributedString(
            string: "Mark up what Claude writes, the way a teacher marks an essay.\n",
            attributes: [.font: Theme.serif(13, italic: true), .foregroundColor: NSColor.labelColor, .paragraphStyle: centred]
        )
        text.append(NSAttributedString(
            // The licence is the panel's last line, from the Info.plist: once is enough.
            string: "Nothing you review leaves this Mac except what you send back.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: centred]
        ))
        return text
    }()
}

/// The app icon in miniature: the tile in outline, with rows of text and the
/// middle one struck out. A template image, so the menu bar colours it.
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    static func image() -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            draw()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Annotator"
        return image
    }

    /// Drawn top-down on the 18-point grid.
    private static func draw() {
        NSColor.black.setStroke()
        let tile = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 1.75, width: 14.5, height: 14.5), xRadius: 4.3, yRadius: 4.3)
        tile.lineWidth = 1.5
        tile.stroke()

        NSColor.black.setFill()
        row(y: 5, width: 8.5)
        row(y: 11.4, width: 5)
        // Struck words recede, as on the page.
        NSColor.black.withAlphaComponent(0.4).setFill()
        row(y: 8.2, width: 7.5)

        // The pen stroke: not quite level, and a little past both ends.
        let strike = NSBezierPath()
        strike.move(to: NSPoint(x: 3.9, y: 9.15))
        strike.curve(to: NSPoint(x: 12.7, y: 8.75), controlPoint1: NSPoint(x: 6.3, y: 8.6), controlPoint2: NSPoint(x: 9, y: 9.4))
        strike.lineWidth = 1.3
        strike.lineCapStyle = .round
        strike.stroke()
    }

    private static func row(y: CGFloat, width: CGFloat) {
        NSBezierPath(roundedRect: NSRect(x: 4.5, y: y, width: width, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
    }
}

/// A menu-bar app shows no menu bar of its own, but text fields only get
/// copy, paste, undo and select-all through the Edit menu's key equivalents.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        // These reach the app delegate, which owns the windows.
        let app = NSMenu()
        app.addItem(withTitle: "About Annotator", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        app.addItem(withTitle: "History…", action: #selector(AppDelegate.showHistory(_:)), keyEquivalent: "y")
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        app.addItem(submenu(services, title: "Services"))
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Annotator", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Annotator", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, title: "Annotator"))

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(file, title: "File"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "Edit"))

        // AppKit lists the open windows at the end of this one.
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window

        // AppKit adds the search field that finds any command by name.
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Practice Review", action: #selector(AppDelegate.showPracticeReview(_:)), keyEquivalent: "")
        main.addItem(submenu(help, title: "Help"))
        NSApp.helpMenu = help

        return main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
