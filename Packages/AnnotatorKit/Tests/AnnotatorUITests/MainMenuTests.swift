import AppKit
import Testing
@testable import AnnotatorUI

@MainActor
@Suite("The menu bar")
struct MainMenuTests {
    private func items(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(items) ?? []) }
    }

    @Test func theMenusAreTheOnesAMacAppHas() {
        _ = NSApplication.shared
        let menu = MainMenu.make()
        #expect(menu.items.map(\.title) == ["Annotator", "File", "Edit", "Window", "Help"])
        #expect(NSApp.windowsMenu?.title == "Window")
        #expect(NSApp.helpMenu?.title == "Help")
        #expect(NSApp.servicesMenu != nil)
    }

    @Test func noTwoCommandsShareAShortcut() {
        _ = NSApplication.shared
        let shortcuts = items(MainMenu.make())
            .filter { !$0.keyEquivalent.isEmpty }
            .map { "\($0.keyEquivalentModifierMask.rawValue) \($0.keyEquivalent)" }
        #expect(Set(shortcuts).count == shortcuts.count)
        #expect(shortcuts.count == 13)
    }

    @Test func everyCommandHasSomethingToDo() {
        _ = NSApplication.shared
        for item in items(MainMenu.make()) where !item.isSeparatorItem && item.submenu == nil {
            #expect(item.action != nil, "\(item.title) does nothing")
        }
    }
}
