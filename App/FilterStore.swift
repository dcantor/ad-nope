import CryptoKit
import Foundation
import Observation
import SafariServices

/// Downloads rule lists from your filter server, merges in your allowlist, and
/// tells Safari to reload each content blocker.
///
/// The filter server is any static host serving what `tools/build_filters.py`
/// writes to `dist/`: `manifest.json` plus one JSON file per blocker.
@MainActor @Observable
final class FilterStore {
    static let shared = FilterStore()

    struct Status {
        var enabled: Bool?   // nil = unknown (for example, the simulator before Safari has loaded it)
        var rules: Int?
        var updated: Date?
    }

    private(set) var statuses: [Blocker: Status] = [:]
    private(set) var allowlist: [String]
    private(set) var isWorking = false
    private(set) var lastChecked: Date?
    var lastError: String?
    var serverURL: String {
        didSet { defaults.set(serverURL, forKey: Keys.serverURL) }
    }

    private let defaults: UserDefaults
    private let appBundleID = Bundle.main.bundleIdentifier ?? ""

    private enum Keys {
        static let serverURL = "serverURL"
        static let allowlist = "allowlist"
        static let lastChecked = "lastChecked"
        static func sha(_ b: Blocker) -> String { "sha.\(b.rawValue)" }
        static func rules(_ b: Blocker) -> String { "rules.\(b.rawValue)" }
        static func updated(_ b: Blocker) -> String { "updated.\(b.rawValue)" }
    }

    private init() {
        defaults = RuleStorage.sharedDefaults ?? .standard
        allowlist = defaults.stringArray(forKey: Keys.allowlist) ?? []
        serverURL = defaults.string(forKey: Keys.serverURL) ?? ""
        lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
        for b in Blocker.allCases {
            statuses[b] = Status(rules: defaults.object(forKey: Keys.rules(b)) as? Int,
                                 updated: defaults.object(forKey: Keys.updated(b)) as? Date)
        }
    }

    // MARK: - Safari state

    func refreshStates() async {
        for b in Blocker.allCases {
            let state = try? await SFContentBlockerManager.stateOfContentBlocker(
                withIdentifier: b.extensionBundleID(appBundleID: appBundleID))
            statuses[b, default: Status()].enabled = state?.isEnabled
        }
    }

    // MARK: - Updating

    var canUpdate: Bool { serverBase != nil }

    private var serverBase: URL? {
        let s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s.hasSuffix("/") ? s : s + "/"),
              url.scheme == "https" || url.scheme == "http", url.host() != nil else { return nil }
        return url
    }

    /// Updates if the last successful check was more than `maxAge` ago.
    func updateIfStale(maxAge: TimeInterval = 24 * 3600) async {
        guard canUpdate, (lastChecked ?? .distantPast).timeIntervalSinceNow < -maxAge else { return }
        await updateFilters()
    }

    func updateFilters() async {
        guard let base = serverBase else {
            lastError = "Set a filter server URL first."
            return
        }
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        lastError = nil
        do {
            let manifest = try JSONDecoder().decode(Manifest.self,
                                                    from: try await fetch(base.appendingPathComponent("manifest.json")))
            for b in Blocker.allCases {
                guard let entry = manifest.blockers[b.rawValue],
                      defaults.string(forKey: Keys.sha(b)) != entry.sha256 else { continue }
                let data = try await fetch(base.appendingPathComponent(entry.file))
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == entry.sha256 else { throw UpdateError.checksum(b.title) }
                try await install(data, for: b)
                defaults.set(entry.sha256, forKey: Keys.sha(b))
                defaults.set(Date(), forKey: Keys.updated(b))
                statuses[b, default: Status()].updated = Date()
            }
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Keys.lastChecked)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Saves a newly downloaded list and applies it. If Safari refuses to
    /// compile it, the previous list is restored so the blocker keeps working.
    private func install(_ data: Data, for b: Blocker) async throws {
        guard let baseURL = RuleStorage.baseURL(for: b) else { throw UpdateError.noAppGroup }
        try FileManager.default.createDirectory(at: baseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let previous = try? Data(contentsOf: baseURL)
        try data.write(to: baseURL, options: .atomic)
        do {
            try await apply(b)
        } catch {
            if let previous { try? previous.write(to: baseURL, options: .atomic) } else { try? FileManager.default.removeItem(at: baseURL) }
            try? await apply(b)
            throw UpdateError.safariRejected(b.title, error.localizedDescription)
        }
    }

    // MARK: - Allowlist

    func allow(_ input: String) async -> Bool {
        guard let domain = Self.normalizeDomain(input) else { return false }
        if !allowlist.contains(domain) {
            allowlist.append(domain)
            allowlist.sort()
            await allowlistChanged()
        }
        return true
    }

    func disallow(_ domains: [String]) async {
        allowlist.removeAll { domains.contains($0) }
        await allowlistChanged()
    }

    private func allowlistChanged() async {
        defaults.set(allowlist, forKey: Keys.allowlist)
        lastError = nil
        do {
            for b in Blocker.allCases { try await apply(b) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// "https://www.Example.com/page" -> "example.com"
    nonisolated static func normalizeDomain(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let host = URL(string: s.contains("://") ? s : "https://\(s)")?.host() { s = host }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard s.contains("."), !s.hasPrefix("."), !s.hasSuffix("."), s.allSatisfy(allowed.contains) else { return nil }
        return s
    }

    // MARK: - Composing what Safari loads

    /// Writes base list + allowlist to the file the extension hands Safari, then reloads it.
    private func apply(_ b: Blocker) async throws {
        guard let base = RuleStorage.baseURL(for: b), let active = RuleStorage.activeURL(for: b) else {
            throw UpdateError.noAppGroup
        }
        let source = FileManager.default.fileExists(atPath: base.path) ? base : bundledSeed(for: b)
        guard let source else { throw UpdateError.missingSeed(b.title) }
        let allow = allowlist
        // Parsing a full list can take a moment; keep it off the main thread.
        let count = try await Task.detached(priority: .userInitiated) {
            try Self.compose(source: source, allowlist: allow, to: active)
        }.value
        try await SFContentBlockerManager.reloadContentBlocker(withIdentifier: b.extensionBundleID(appBundleID: appBundleID))
        statuses[b, default: Status()].rules = count
        defaults.set(count, forKey: Keys.rules(b))
    }

    nonisolated private static func compose(source: URL, allowlist: [String], to target: URL) throws -> Int {
        let data = try Data(contentsOf: source)
        guard var rules = try JSONSerialization.jsonObject(with: data) as? [Any] else { throw UpdateError.badList }
        // Allowlist rules go last: ignore-previous-rules only cancels rules above it.
        for domain in allowlist {
            rules.append([
                "trigger": ["url-filter": ".*", "if-domain": ["*\(domain)"]],
                "action": ["type": "ignore-previous-rules"],
            ])
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: rules, options: [.withoutEscapingSlashes])
        try out.write(to: target, options: .atomic)
        return rules.count
    }

    /// The starter list inside the extension's own bundle, used until the first download.
    private func bundledSeed(for b: Blocker) -> URL? {
        let id = b.extensionBundleID(appBundleID: appBundleID)
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
        else { return nil }
        return items.lazy
            .compactMap(Bundle.init(url:))
            .first { $0.bundleIdentifier == id }?
            .url(forResource: "blockerList", withExtension: "json")
    }

    /// Applies the bundled starter lists on first launch so the allowlist and rule counts work before any download.
    func bootstrap() async {
        guard Blocker.allCases.contains(where: { statuses[$0]?.rules == nil }) else { return }
        for b in Blocker.allCases where statuses[b]?.rules == nil {
            try? await apply(b)
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.http(url.lastPathComponent, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
}

private struct Manifest: Decodable {
    struct Entry: Decodable {
        let file: String
        let sha256: String
        let rules: Int
    }
    let version: Int
    let blockers: [String: Entry]
}

enum UpdateError: LocalizedError {
    case noAppGroup, badList
    case missingSeed(String)
    case checksum(String)
    case http(String, Int)
    case safariRejected(String, String)

    var errorDescription: String? {
        switch self {
        case .noAppGroup: "The shared App Group container isn't available. Check the App Group entitlement."
        case .badList: "A rule list isn't a JSON array."
        case .missingSeed(let name): "No bundled starter list for \(name)."
        case .checksum(let name): "\(name) list failed its checksum; kept the previous version."
        case .http(let file, let code): "Couldn't download \(file) (HTTP \(code))."
        case .safariRejected(let name, let why): "Safari rejected the new \(name) list, so the previous one was kept. \(why)"
        }
    }
}
