import AppKit
import Testing
@testable import AnnotatorUI

@MainActor
@Suite("Opening the app")
struct OpeningTests {
    private final class Shown: NSWindow {
        override var isVisible: Bool { true }
    }

    private final class Minimized: NSWindow {
        override var isMiniaturized: Bool { true }
    }

    private func window<Window: NSWindow>(_ type: Window.Type, _ style: NSWindow.StyleMask) -> Window {
        let window = Window(contentRect: .zero, styleMask: style, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func onlyAPersonOpeningTheAppGetsAWindow() {
        // From Finder, Spotlight or Launchpad.
        #expect(Opening.isByHand(arguments: ["Annotator"], isDefaultLaunch: true, atLogin: false))
        // The command-line tool starting it for the review that follows.
        #expect(!Opening.isByHand(arguments: ["Annotator", "--background"], isDefaultLaunch: true, atLogin: false))
        #expect(!Opening.isByHand(arguments: ["Annotator", "--review", "plan.md"], isDefaultLaunch: true, atLogin: false))
        // At login it only takes its place in the menu bar.
        #expect(!Opening.isByHand(arguments: ["Annotator"], isDefaultLaunch: true, atLogin: true))
        // Launched to open a file, a link from the Share menu or a Services request.
        #expect(!Opening.isByHand(arguments: ["Annotator"], isDefaultLaunch: false, atLogin: false))
    }

    @Test func openingItAgainBringsBackAWindowItHas() {
        _ = NSApplication.shared
        let menuBarIcon = window(Shown.self, [.borderless])
        #expect(!Opening.hasWindow([menuBarIcon]))
        #expect(Opening.hasWindow([menuBarIcon, window(Shown.self, [.titled])]))
        #expect(Opening.hasWindow([window(Minimized.self, [.titled, .miniaturizable])]))
        // A window that was closed is not one to bring back.
        #expect(!Opening.hasWindow([window(NSWindow.self, [.titled])]))
    }
}
