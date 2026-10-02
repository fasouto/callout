import AnnotatorStore
import AppKit
import SwiftUI

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store: Store?
    private let showOnboarding: () -> Void

    init(store: Store?, showOnboarding: @escaping () -> Void) {
        self.store = store
        self.showOnboarding = showOnboarding
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.title = "Annotator Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: TabView {
                SettingsView(showOnboarding: showOnboarding)
                    .tabItem { Label("General", systemImage: "gearshape") }
                SnippetSettings(store: store)
                    .tabItem { Label("Saved Comments", systemImage: "text.badge.plus") }
            }
            .frame(width: 520, height: 560))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct SettingsView: View {
    let showOnboarding: () -> Void

    @State private var hotkey = Hotkey.stored
    @State private var isAllowed = SelectionCapture.isAllowed
    @State private var refused = false
    @State private var copied = false
    @State private var vimKeys = Keymap.usesVimKeys
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    /// The command-line tool inside the app bundle, when there is a bundle.
    private var toolPath: String? {
        let path = Bundle.main.bundlePath + "/Contents/Helpers/annotator"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Mark up the selection") {
                    HotkeyRecorder(hotkey: $hotkey) { new in
                        refused = !HotkeyCenter.shared.register(new)
                        if !refused { Hotkey.stored = new }
                    }
                }
                if refused {
                    Label("Another app already uses that shortcut. Choose a different one.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                LabeledContent("Permission to copy for you") {
                    if isAllowed {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Set Up…", action: showOnboarding)
                    }
                }
            } header: {
                Text("From any app")
            } footer: {
                Text("Select text in any app and press the shortcut. A file dropped on the menu-bar icon, and Annotate with Annotator in an app's Services menu, need no permission.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle("Move with vim keys", isOn: $vimKeys)
                    .onChange(of: vimKeys) { _, isOn in Keymap.usesVimKeys = isOn }
            } header: {
                Text("In a review")
            } footer: {
                Text("h j k l, w b e, 0 $, { }, gg and G move the caret; v starts a selection and V takes the line; n and N go to the next and previous mark; u undoes. Keep moves to ⇧K, and Esc lets go of the selection instead of cancelling the review.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                LabeledContent("Command-line tool") {
                    if let toolPath {
                        Button(copied ? "Copied" : "Copy Install Command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("sudo ln -sf \"\(toolPath)\" /usr/local/bin/annotator", forType: .string)
                            copied = true
                        }
                    } else {
                        Text("Only in the app bundle")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Claude Code")
            } footer: {
                Text("The Claude Code plugin finds the tool by itself. Put it on your PATH only if you want to run annotator in a terminal: paste the copied command there.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(timer) { _ in isAllowed = SelectionCapture.isAllowed }
    }
}

/// Shows the shortcut and, when clicked, takes the next key press as the new one.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    let changed: (Hotkey) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            Text(isRecording ? "Press a shortcut" : hotkey.display)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .frame(minWidth: 110)
        }
        .help(isRecording ? "Press Esc to keep the current shortcut" : "Click, then press the shortcut you want")
        .accessibilityLabel("Shortcut: \(hotkey.display)")
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        // While recording, the current shortcut must reach this window like any other key.
        HotkeyCenter.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == KeyCode.escape {
                stop()
            } else if let new = Hotkey(event: event) {
                hotkey = new
                stop()
                changed(new)
                return nil
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording {
            isRecording = false
            HotkeyCenter.shared.register(hotkey)
        }
    }
}
