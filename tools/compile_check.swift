// Compiles content-blocker JSON with WebKit's rule compiler, the same one
// Safari on iOS uses.
//
//   swift tools/compile_check.swift dist/ads.json ...       check; exit 1 if any file is rejected
//   swift tools/compile_check.swift --prune dist/ads.json   drop the rules WebKit rejects, in place
//
// One invalid rule (for example a CSS selector WebKit can't parse) makes Safari
// reject the whole list, so --prune bisects the list to find and remove only
// the bad rules. Runs on macOS only and compiles into a throwaway store, so it
// doesn't touch Safari's own content blockers.

import Foundation
import WebKit

@MainActor
final class Checker {
    let store: WKContentRuleListStore
    var compiles = 0

    init?(dir: URL) {
        guard let s = WKContentRuleListStore(url: dir) else { return nil }
        store = s
    }

    func compile(_ json: String) async -> Error? {
        compiles += 1
        return await withCheckedContinuation { cont in
            store.compileContentRuleList(forIdentifier: "check", encodedContentRuleList: json) { _, error in
                cont.resume(returning: error)
            }
        }
    }

    func encode(_ rules: ArraySlice<Any>) -> String {
        let data = try! JSONSerialization.data(withJSONObject: Array(rules), options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// Returns the indices of rules WebKit rejects.
    func badRules(_ rules: [Any], _ range: Range<Int>) async -> [Int] {
        if range.isEmpty { return [] }
        if await compile(encode(rules[range])) == nil { return [] }
        if range.count == 1 { return [range.lowerBound] }
        let mid = range.lowerBound + range.count / 2
        let left = await badRules(rules, range.lowerBound..<mid)
        let right = await badRules(rules, mid..<range.upperBound)
        return left + right
    }

    func check(_ path: String) async -> Bool {
        guard let json = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("✗ \(path): can't read file"); return false
        }
        let start = Date()
        if let error = await compile(json) {
            print("✗ \(path): \(error.localizedDescription)"); return false
        }
        print("✓ \(path) compiled in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        return true
    }

    func prune(_ path: String) async -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let rules = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            print("✗ \(path): not a JSON array"); return false
        }
        let bad = Set(await badRules(rules, 0..<rules.count))
        if bad.isEmpty {
            print("✓ \(path): all \(rules.count) rules compile")
            return true
        }
        for i in bad.sorted().prefix(10) {
            print("  dropped: \(encode(rules[i...i]))")
        }
        if bad.count > 10 { print("  … and \(bad.count - 10) more") }
        let kept = rules.enumerated().filter { !bad.contains($0.offset) }.map(\.element)
        let out = try! JSONSerialization.data(withJSONObject: kept, options: [.withoutEscapingSlashes])
        FileManager.default.createFile(atPath: path, contents: out)
        print("✓ \(path): dropped \(bad.count) of \(rules.count) rules (\(compiles) compiles)")
        return true
    }
}

/// Prints the selectors (one per line in `path`) that WebKit's CSS parser rejects.
/// Content blockers silently skip a css-display-none rule if any selector in it is
/// invalid, so build_filters.py filters selectors through this before batching them.
@MainActor
func invalidSelectors(path: String) async -> Bool {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        FileHandle.standardError.write(Data("can't read \(path)\n".utf8)); return false
    }
    let selectors = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    let webView = WKWebView(frame: .zero)
    do {
        let result = try await webView.callAsyncJavaScript("""
            const bad = [];
            for (const s of selectors) { try { document.querySelector(s) } catch (e) { bad.push(s) } }
            return bad;
            """, arguments: ["selectors": selectors], contentWorld: .defaultClient)
        for s in result as? [String] ?? [] { print(s) }
        return true
    } catch {
        FileHandle.standardError.write(Data("selector check failed: \(error)\n".utf8)); return false
    }
}

var args = Array(CommandLine.arguments.dropFirst())
if args.first == "--invalid-selectors", args.count == 2 {
    let ok = await Task { @MainActor in await invalidSelectors(path: args[1]) }.value
    exit(ok ? 0 : 1)
}
let pruneMode = args.first == "--prune"
if pruneMode { args.removeFirst() }
if args.isEmpty {
    print("usage: swift tools/compile_check.swift [--prune] <rules.json>...")
    print("       swift tools/compile_check.swift --invalid-selectors <selectors.txt>")
    exit(2)
}

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rule-check-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

let allGood = await Task { @MainActor in
    guard let checker = Checker(dir: dir) else {
        print("✗ could not create a rule list store"); return false
    }
    var ok = true
    for path in args {
        let good = pruneMode ? await checker.prune(path) : await checker.check(path)
        ok = ok && good
    }
    return ok
}.value
try? FileManager.default.removeItem(at: dir)
exit(allGood ? 0 : 1)
