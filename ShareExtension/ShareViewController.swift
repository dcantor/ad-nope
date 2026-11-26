import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Safari's Share menu › Ad Nope. Receives only the address of the page you
/// shared (nothing from the page itself), and lets you allow or re-block that site.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.close = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let context = extensionContext
        Task { await model.load(from: context) }
    }
}

@MainActor @Observable
final class ShareModel {
    enum Phase {
        case loading
        case ready(domain: String, allowed: Bool)
        case working(domain: String)
        case done(String)
        case failed(String)
    }

    var phase: Phase = .loading
    var close: () -> Void = {}

    func load(from context: NSExtensionContext?) async {
        guard let url = await Self.sharedURL(in: context), let domain = Allowlist.normalize(url.absoluteString) else {
            phase = .failed("This page doesn't have a web address Ad Nope can use.")
            return
        }
        Allowlist.syncFromCloud()
        phase = .ready(domain: domain, allowed: Allowlist.domains.contains(domain))
    }

    func toggle(_ domain: String, currentlyAllowed: Bool) async {
        phase = .working(domain: domain)
        let list = currentlyAllowed ? Allowlist.remove([domain]) : Allowlist.add(domain)
        do {
            _ = try await RuleComposer.applyAll(allowlist: list)
            phase = .done(currentlyAllowed
                          ? "Blocking ads on \(domain) again. Reload the page to see it."
                          : "Ads allowed on \(domain). Reload the page to see it.")
            try? await Task.sleep(for: .seconds(1.6))
            close()
        } catch {
            phase = .failed("Couldn't update Safari: \(error.localizedDescription)")
        }
    }

    private static func sharedURL(in context: NSExtensionContext?) async -> URL? {
        let items = context?.inputItems as? [NSExtensionItem] ?? []
        for provider in items.flatMap({ $0.attachments ?? [] })
        where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                return url
            }
        }
        return nil
    }
}

struct ShareView: View {
    let model: ShareModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Ad Nope")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.close() }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
        case .ready(let domain, let allowed):
            Image(systemName: allowed ? "rectangle.slash" : "hand.thumbsup")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(allowed ? "Block ads on \(domain) again?" : "Allow ads on \(domain)?")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(allowed
                 ? "Ad Nope will block ads and trackers on \(domain) and its subdomains again."
                 : "Ad Nope won't block anything on \(domain) or its subdomains. Useful when a site breaks or asks you to turn off your blocker.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await model.toggle(domain, currentlyAllowed: allowed) }
            } label: {
                Text(allowed ? "Block ads again" : "Allow ads")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .working(let domain):
            ProgressView()
            Text("Updating Safari for \(domain)…")
                .foregroundStyle(.secondary)
        case .done(let message):
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text(message)
                .multilineTextAlignment(.center)
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
        }
    }
}
