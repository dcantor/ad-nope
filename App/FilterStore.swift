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

    /// Where the daily GitHub Action publishes the lists (see .github/workflows/filters.yml).
    /// Used until the user enters a different server.
    static let defaultServerURL = "https://dcantor.github.io/ad-nope/"

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
    private let appBundleID = AppIdentity.appBundleID
    private var cloudObserver: NSObjectProtocol?

    private enum Keys {
        static let serverURL = "serverURL"
        static let lastChecked = "lastChecked"
        static func sha(_ b: Blocker) -> String { "sha.\(b.rawValue)" }
        static func rules(_ b: Blocker) -> String { RuleStorage.activeRulesKey(b) }
        static func updated(_ b: Blocker) -> String { "updated.\(b.rawValue)" }
    }

    private init() {
        defaults = RuleStorage.sharedDefaults ?? .standard
        allowlist = Allowlist.domains
        serverURL = defaults.string(forKey: Keys.serverURL) ?? Self.defaultServerURL
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
                try await install(data, rules: entry.rules, for: b)
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
    private func install(_ data: Data, rules: Int, for b: Blocker) async throws {
        guard let baseURL = RuleStorage.baseURL(for: b) else { throw RuleError.noAppGroup }
        try FileManager.default.createDirectory(at: baseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let previous = try? Data(contentsOf: baseURL)
        let previousRules = defaults.object(forKey: RuleStorage.baseRulesKey(b))
        try data.write(to: baseURL, options: .atomic)
        defaults.set(rules, forKey: RuleStorage.baseRulesKey(b))
        do {
            try await apply(b)
        } catch {
            if let previous { try? previous.write(to: baseURL, options: .atomic) } else { try? FileManager.default.removeItem(at: baseURL) }
            defaults.set(previousRules, forKey: RuleStorage.baseRulesKey(b))
            try? await apply(b)
            throw UpdateError.safariRejected(b.title, error.localizedDescription)
        }
    }

    // MARK: - Allowlist

    func allow(_ input: String) async -> Bool {
        guard let domain = Allowlist.normalize(input) else { return false }
        if !allowlist.contains(domain) {
            allowlist = Allowlist.add(domain)
            await applyAll()
        }
        return true
    }

    func disallow(_ domains: [String]) async {
        allowlist = Allowlist.remove(domains)
        await applyAll()
    }

    /// Picks up changes made elsewhere: the Share extension (same App Group) or
    /// another device (iCloud). Re-applies the blockers only if something changed.
    func syncAllowlist() async {
        let cloudChanged = Allowlist.syncFromCloud()
        let current = Allowlist.domains
        // The Share extension may have updated the blockers (and their counts) already.
        for b in Blocker.allCases {
            if let n = defaults.object(forKey: Keys.rules(b)) as? Int { statuses[b, default: Status()].rules = n }
        }
        guard cloudChanged || current != allowlist else { return }
        allowlist = current
        await applyAll()
    }

    /// Re-syncs whenever iCloud reports a change from another device.
    func observeCloud() {
        guard cloudObserver == nil else { return }
        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default, queue: .main
        ) { [weak self] _ in
            Task { await self?.syncAllowlist() }
        }
    }

    private func applyAll() async {
        lastError = nil
        do {
            for b in Blocker.allCases { try await apply(b) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Composing what Safari loads

    private func apply(_ b: Blocker) async throws {
        // RuleComposer also saves the count, so the Share extension's updates show up here.
        if let count = try await RuleComposer.apply(b, allowlist: allowlist) {
            statuses[b, default: Status()].rules = count
        }
    }

    /// Applies the bundled starter lists on first launch so the allowlist and rule counts work before any download.
    func bootstrap() async {
        // Installs from before baseRules existed: count the downloaded lists once.
        for b in Blocker.allCases where defaults.object(forKey: RuleStorage.baseRulesKey(b)) == nil {
            if let url = RuleStorage.baseURL(for: b), let data = try? Data(contentsOf: url),
               let rules = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                defaults.set(rules.count, forKey: RuleStorage.baseRulesKey(b))
            }
        }
        observeCloud()
        await syncAllowlist()
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
    case checksum(String)
    case http(String, Int)
    case safariRejected(String, String)

    var errorDescription: String? {
        switch self {
        case .checksum(let name): "\(name) list failed its checksum; kept the previous version."
        case .http(let file, let code): "Couldn't download \(file) (HTTP \(code))."
        case .safariRejected(let name, let why): "Safari rejected the new \(name) list, so the previous one was kept. \(why)"
        }
    }
}
