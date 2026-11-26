import Foundation

/// Settings for Extras › Dark mode for websites. Stored in the App Group so the
/// Ad Nope Dark web extension's native handler can read them.
struct DarkModeSettings: Equatable {
    enum When: String, CaseIterable, Identifiable {
        case matchDevice = "system"  // only while the iPhone, iPad or Mac is in dark mode
        case always = "always"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .matchDevice: "When my device is in dark mode"
            case .always: "Always"
            }
        }
    }

    /// On by default: allowing Ad Nope Dark in Safari is the opt-in, so there's
    /// no second switch to find. The app and the toolbar popup can turn it off.
    var enabled = true
    var when: When = .matchDevice
    /// Sites that are never darkened (and their subdomains).
    var excluded: [String] = []

    private enum Keys {
        static let enabled = "dark.enabled"
        static let when = "dark.when"
        static let excluded = "dark.excluded"
    }

    static func load() -> DarkModeSettings {
        let d = RuleStorage.sharedDefaults
        return DarkModeSettings(
            enabled: d?.object(forKey: Keys.enabled) as? Bool ?? true,
            when: When(rawValue: d?.string(forKey: Keys.when) ?? "") ?? .matchDevice,
            excluded: d?.stringArray(forKey: Keys.excluded) ?? [])
    }

    func save() {
        let d = RuleStorage.sharedDefaults
        d?.set(enabled, forKey: Keys.enabled)
        d?.set(when.rawValue, forKey: Keys.when)
        d?.set(excluded, forKey: Keys.excluded)
    }

    /// Darken `site` or not. Re-enabling also clears any parent-domain entry
    /// that covers it (allowing news.example.com clears example.com).
    mutating func setDarkens(_ site: String, _ darken: Bool) {
        if darken {
            excluded.removeAll { site == $0 || site.hasSuffix("." + $0) }
        } else if !excluded.contains(site) {
            excluded.append(site)
            excluded.sort()
        }
    }

    /// What the web extension receives. Contains only these settings, never anything about pages.
    var message: [String: Any] {
        ["enabled": enabled, "mode": when.rawValue, "excluded": excluded]
    }
}
