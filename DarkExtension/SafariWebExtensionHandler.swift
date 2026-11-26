import Foundation
import SafariServices

/// The Ad Nope Dark extension's link to the app's settings (App Group).
///
///   {type: "dark-settings"}                        -> current settings
///   {type: "dark-set", enabled: Bool}              -> turn dark mode on or off
///   {type: "dark-set", site: "host", darken: Bool} -> darken this site or not
///
/// Every reply is the current settings. Only settings come in and go out;
/// nothing about page content.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]

        var settings = DarkModeSettings.load()
        if message["type"] as? String == "dark-set" {
            if let enabled = message["enabled"] as? Bool {
                settings.enabled = enabled
            }
            if let site = (message["site"] as? String).flatMap(Allowlist.normalize),
               let darken = message["darken"] as? Bool {
                settings.setDarkens(site, darken)
            }
            settings.save()
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: settings.message]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
