import Foundation

/// The three content-blocker extensions. Each one is a separate extension so it
/// gets its own 150,000-rule budget and can be switched on and off on its own in
/// Settings › Apps › Safari › Extensions.
///
/// Compiled into the app and into every extension.
enum Blocker: String, CaseIterable, Identifiable, Codable, Sendable {
    case ads, privacy, annoyances

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ads: "Ads"
        case .privacy: "Trackers"
        case .annoyances: "Annoyances"
        }
    }

    var summary: String {
        switch self {
        case .ads: "Ad networks and ad slots (EasyList)."
        case .privacy: "Analytics and tracking pixels (EasyPrivacy)."
        case .annoyances: "Cookie banners, pop-ups and social widgets (Fanboy)."
        }
    }

    var systemImage: String {
        switch self {
        case .ads: "rectangle.slash"
        case .privacy: "eye.slash"
        case .annoyances: "hand.raised"
        }
    }

    /// Extension bundle IDs are `<app bundle ID>.<rawValue>`; see the project's build settings.
    func extensionBundleID(appBundleID: String) -> String { "\(appBundleID).\(rawValue)" }

    /// Which blocker an extension is, from its own bundle ID.
    init?(extensionBundleID: String?) {
        guard let last = extensionBundleID?.split(separator: ".").last,
              let blocker = Blocker(rawValue: String(last)) else { return nil }
        self = blocker
    }
}

/// Where rule lists live in the shared App Group container.
///
///   Rules/<name>.base.json   last list downloaded from the filter server
///   Rules/<name>.json        base list plus your allowlist; what Safari loads
enum RuleStorage {
    /// The App Group ID, read from Info.plist (`BlockerAppGroup`), which is set from the
    /// `APP_GROUP_ID` build setting so it's only defined in one place.
    static var appGroupID: String {
        Bundle.main.object(forInfoDictionaryKey: "BlockerAppGroup") as? String ?? ""
    }

    static var directory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("Rules", isDirectory: true)
    }

    static func baseURL(for blocker: Blocker) -> URL? {
        directory?.appendingPathComponent("\(blocker.rawValue).base.json")
    }

    static func activeURL(for blocker: Blocker) -> URL? {
        directory?.appendingPathComponent("\(blocker.rawValue).json")
    }

    static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    /// Rule count of the downloaded base list (from the manifest), in sharedDefaults.
    static func baseRulesKey(_ blocker: Blocker) -> String { "baseRules.\(blocker.rawValue)" }

    /// Rule count Safari currently has for the blocker (base + allowlist), in sharedDefaults.
    static func activeRulesKey(_ blocker: Blocker) -> String { "rules.\(blocker.rawValue)" }
}
