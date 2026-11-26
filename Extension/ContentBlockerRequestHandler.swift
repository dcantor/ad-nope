import Foundation

/// Safari calls this when it needs this extension's rules: on first enable, and
/// whenever the app calls `SFContentBlockerManager.reloadContentBlocker`.
///
/// It doesn't parse anything. It hands Safari a file URL, so memory use stays
/// tiny even for a 150,000-rule list. It never sees the pages you visit.
///
/// The same file is compiled into all three extensions; the extension's
/// bundle ID tells it which blocker it is.
final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = NSExtensionItem()
        if let url = rulesURL(), let provider = NSItemProvider(contentsOf: url) {
            item.attachments = [provider]
        }
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }

    private func rulesURL() -> URL? {
        // Prefer the list the app composed (latest download plus allowlist)...
        if let blocker = Blocker(extensionBundleID: Bundle.main.bundleIdentifier),
           let url = RuleStorage.activeURL(for: blocker),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        // ...and fall back to the starter list bundled with this extension.
        return Bundle.main.url(forResource: "blockerList", withExtension: "json")
    }
}
