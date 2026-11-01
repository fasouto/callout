import AppKit
import UniformTypeIdentifiers

/// The Share menu entry: hands the shared file to the app and gets out of the
/// way. It has no interface of its own.
///
/// An app extension runs sandboxed, so it cannot talk to the app's socket. It
/// passes the file's path through a `callout://` link instead, and the app,
/// which is not sandboxed, opens the file itself.
final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            finish()
            return
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
            var path: String?
            if let url = item as? URL {
                path = url.path
            } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                path = url.path
            }
            DispatchQueue.main.async {
                if let path { Self.open(path) }
                self?.finish()
            }
        }
    }

    private static func open(_ path: String) {
        var link = URLComponents()
        link.scheme = "callout"
        link.host = "open"
        link.queryItems = [URLQueryItem(name: "path", value: path)]
        if let url = link.url { NSWorkspace.shared.open(url) }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
