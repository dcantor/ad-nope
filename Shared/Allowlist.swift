import Foundation

/// Your allowed sites. Stored in the App Group so the app and the Share
/// extension see the same list, and mirrored to iCloud key-value storage so
/// your iPhone, iPad and Mac share one list.
///
/// iCloud key-value storage is free, private to your Apple Account, and syncs
/// within seconds to minutes. Without iCloud the list simply stays local.
enum Allowlist {
    private static let key = "allowlist"
    private static let mergedKey = "allowlist.mergedWithCloud"

    static var domains: [String] { local }

    @discardableResult
    static func add(_ domain: String) -> [String] { save(Set(local).union([domain])) }

    @discardableResult
    static func remove(_ domains: [String]) -> [String] { save(Set(local).subtracting(domains)) }

    /// Pulls the iCloud copy into the local list. The first time on a device the
    /// two are merged, so nothing is lost; after that iCloud wins, so removals
    /// made on another device carry over. Returns true if the local list changed.
    @discardableResult
    static func syncFromCloud() -> Bool {
        cloud.synchronize()
        let before = local
        let remote = (cloud.array(forKey: key) as? [String])?.compactMap(normalize)
        let defaults = RuleStorage.sharedDefaults
        if defaults?.bool(forKey: mergedKey) != true {
            defaults?.set(true, forKey: mergedKey)
            save(Set(before).union(remote ?? []))
        } else if let remote {
            local = Set(remote).sorted()
        } else if !before.isEmpty {
            save(Set(before))  // iCloud has nothing yet: seed it
        }
        return local != before
    }

    /// "https://www.Example.com/page" -> "example.com". Returns nil for anything
    /// that isn't a plain ASCII domain, which also keeps it safe to put in JSON.
    static func normalize(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let host = URL(string: s.contains("://") ? s : "https://\(s)")?.host() { s = host }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard s.contains("."), !s.hasPrefix("."), !s.hasSuffix("."), s.allSatisfy(allowed.contains) else { return nil }
        return s
    }

    // MARK: - Storage

    private static var cloud: NSUbiquitousKeyValueStore { .default }

    private static var local: [String] {
        get { RuleStorage.sharedDefaults?.stringArray(forKey: key) ?? [] }
        set { RuleStorage.sharedDefaults?.set(newValue, forKey: key) }
    }

    @discardableResult
    private static func save(_ set: Set<String>) -> [String] {
        let list = set.sorted()
        local = list
        cloud.set(list, forKey: key)
        cloud.synchronize()
        return list
    }
}
