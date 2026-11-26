import Foundation
import SafariServices

/// Builds the rule file each content blocker hands Safari (base list + allowlist)
/// and asks Safari to reload it. Used by the app and by the Share extension.
///
/// Composing works on bytes rather than parsing JSON: the Ads list is about
/// 9 MB, and parsing it into objects would blow past an extension's memory limit.
enum RuleComposer {
    /// Writes `<blocker>.json` = base list + one ignore-previous-rules rule per
    /// allowed domain, then reloads the blocker. Returns the total rule count
    /// when it's known.
    @discardableResult
    static func apply(_ blocker: Blocker, allowlist: [String]) async throws -> Int? {
        guard let active = RuleStorage.activeURL(for: blocker) else { throw RuleError.noAppGroup }
        guard let source = baseList(for: blocker) else { throw RuleError.missingSeed(blocker.title) }
        let count = try await Task.detached(priority: .userInitiated) {
            try compose(source: source, allowlist: allowlist, to: active)
            return baseRuleCount(for: blocker, source: source).map { $0 + allowlist.count }
        }.value
        try await SFContentBlockerManager.reloadContentBlocker(
            withIdentifier: blocker.extensionBundleID(appBundleID: AppIdentity.appBundleID))
        if let count { RuleStorage.sharedDefaults?.set(count, forKey: RuleStorage.activeRulesKey(blocker)) }
        return count
    }

    /// Applies every blocker; stops at the first error.
    static func applyAll(allowlist: [String]) async throws -> [Blocker: Int] {
        var counts: [Blocker: Int] = [:]
        for b in Blocker.allCases {
            if let n = try await apply(b, allowlist: allowlist) { counts[b] = n }
        }
        return counts
    }

    /// The last downloaded list, or the starter list bundled in the extension.
    static func baseList(for blocker: Blocker) -> URL? {
        if let url = RuleStorage.baseURL(for: blocker), FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return bundledSeed(for: blocker)
    }

    static func bundledSeed(for blocker: Blocker) -> URL? {
        let id = blocker.extensionBundleID(appBundleID: AppIdentity.appBundleID)
        guard let plugins = AppIdentity.pluginsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
        else { return nil }
        return items.lazy
            .compactMap(Bundle.init(url:))
            .first { $0.bundleIdentifier == id }?
            .url(forResource: "blockerList", withExtension: "json")
    }

    /// Rule count of the base list. Downloads record it from the manifest; the
    /// small bundled seeds are counted directly.
    static func baseRuleCount(for blocker: Blocker, source: URL) -> Int? {
        if source == RuleStorage.baseURL(for: blocker) {
            return RuleStorage.sharedDefaults?.object(forKey: RuleStorage.baseRulesKey(blocker)) as? Int
        }
        guard let data = try? Data(contentsOf: source),
              let rules = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        return rules.count
    }

    static func compose(source: URL, allowlist: [String], to target: URL) throws {
        var data = try Data(contentsOf: source)
        let whitespace: Set<UInt8> = [0x20, 0x0A, 0x0D, 0x09]
        while let last = data.last, whitespace.contains(last) { data.removeLast() }
        guard data.last == UInt8(ascii: "]") else { throw RuleError.badList }
        data.removeLast()
        // Is the array empty? Only "[" and whitespace left.
        let isEmpty = data.filter { !whitespace.contains($0) } == Data("[".utf8)
        for (i, domain) in allowlist.enumerated() {
            // Domains are validated by Allowlist.normalize: [a-z0-9.-] only, so safe inside a JSON string.
            let rule = #"{"trigger":{"url-filter":".*","if-domain":["*\#(domain)"]},"action":{"type":"ignore-previous-rules"}}"#
            data.append(contentsOf: Array(((isEmpty && i == 0) ? "" : ",").utf8))
            data.append(contentsOf: Array(rule.utf8))
        }
        data.append(UInt8(ascii: "]"))
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }
}

enum RuleError: LocalizedError {
    case noAppGroup, badList
    case missingSeed(String)

    var errorDescription: String? {
        switch self {
        case .noAppGroup: "The shared App Group container isn't available. Check the App Group entitlement."
        case .badList: "A rule list isn't a JSON array."
        case .missingSeed(let name): "No bundled starter list for \(name)."
        }
    }
}

/// Facts about the running bundle that differ between the app and its extensions.
enum AppIdentity {
    static var isExtension: Bool { Bundle.main.bundleURL.pathExtension == "appex" }

    /// The containing app's bundle ID, from the app or any of its extensions.
    static var appBundleID: String {
        let id = Bundle.main.bundleIdentifier ?? ""
        return isExtension ? id.split(separator: ".").dropLast().joined(separator: ".") : id
    }

    /// The app's PlugIns folder, where the content-blocker extensions live.
    static var pluginsURL: URL? {
        isExtension ? Bundle.main.bundleURL.deletingLastPathComponent() : Bundle.main.builtInPlugInsURL
    }
}
