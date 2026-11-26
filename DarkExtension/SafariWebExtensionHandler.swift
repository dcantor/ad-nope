import Foundation
import SafariServices

/// Answers the Ad Nope Dark extension's one question: "what are the dark-mode
/// settings?" It reads them from the App Group, where the app saves them. No
/// page data comes in here; the extension only asks for settings.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: DarkModeSettings.load().message]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
