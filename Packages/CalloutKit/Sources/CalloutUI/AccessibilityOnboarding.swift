import AppKit
import SwiftUI

/// Explains why the hotkey needs the Accessibility permission, takes the user
/// to the setting, and notices by itself when the permission has been given.
@MainActor
final class AccessibilityOnboarding: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: OnboardingView(hotkey: Hotkey.stored.display) { [weak self] in
                self?.window?.close()
            })
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

struct OnboardingView: View {
    let hotkey: String
    let close: () -> Void

    @State private var isAllowed = SelectionCapture.isAllowed
    /// When Settings was opened from here.
    @State private var askedAt: Date?
    /// Still waiting well after Settings was opened: the switch that is on
    /// probably belongs to an earlier copy of the app.
    @State private var looksStale = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// How long after opening Settings the hint about an earlier copy appears.
    static let staleAfter: TimeInterval = 12

    init(hotkey: String, looksStale: Bool = false, close: @escaping () -> Void) {
        self.hotkey = hotkey
        self.close = close
        _looksStale = State(initialValue: looksStale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .padding(.bottom, 14)
                .accessibilityHidden(true)

            Text("Mark up text from any app")
                .font(.system(size: 22, weight: .bold, design: .serif))
                .padding(.bottom, 8)

            Text("Select text anywhere and press \(hotkey). Callout copies the selection, opens it for you to mark up, and puts your clipboard back the way it was.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 12) {
                step(1, "Open Accessibility settings", done: isAllowed)
                step(2, "Turn on Callout in the list", done: isAllowed)
            }
            .padding(.bottom, 14)

            Text("Copying for you means pressing ⌘C in another app, and macOS only lets an app do that with your permission. Callout uses it for nothing else.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if looksStale, !isAllowed {
                // macOS remembers the permission for one exact copy of the app,
                // and each new build is a new copy.
                Label("Callout already switched on? That is an earlier copy of the app. Select it in the list, remove it with −, then press Open Settings again.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            Spacer(minLength: 18)

            HStack {
                if isAllowed {
                    Label("Allowed. Try \(hotkey) on a selection.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Waiting for permission")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isAllowed {
                    Button("Done", action: close)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now", action: close)
                        .keyboardShortcut(.cancelAction)
                    Button("Open Settings") {
                        askedAt = Date()
                        looksStale = false
                        SelectionCapture.requestPermission()
                        SelectionCapture.openSettings()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 22)
        .frame(width: 480, height: 420, alignment: .topLeading)
        .onReceive(timer) { now in
            isAllowed = SelectionCapture.isAllowed
            if !isAllowed, let askedAt, now.timeIntervalSince(askedAt) > Self.staleAfter { looksStale = true }
        }
    }

    private func step(_ number: Int, _ text: String, done: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.secondary.opacity(0.18))
                    .frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            Text(text)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(text)\(done ? ", done" : "")")
    }
}
