import SwiftUI

struct ContentView: View {
    @Environment(FilterStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var newDomain = ""
    @State private var domainInvalid = false

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            List {
                Section {
                    ForEach(Blocker.allCases) { blocker in
                        BlockerRow(blocker: blocker, status: store.statuses[blocker] ?? .init())
                    }
                } header: {
                    Text("Blockers")
                } footer: {
                    Text("Turn each one on in Settings › Apps › Safari › Extensions. The blockers only give Safari a list of rules; they can't see the pages you visit.")
                }

                Section {
                    Button {
                        Task { await store.updateFilters() }
                    } label: {
                        HStack {
                            Label("Update Filters Now", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if store.isWorking { ProgressView() }
                        }
                    }
                    .disabled(!store.canUpdate || store.isWorking)
                    if let checked = store.lastChecked {
                        LabeledContent("Last checked", value: checked.formatted(.relative(presentation: .named)))
                    }
                    if let error = store.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Filters")
                } footer: {
                    if !store.canUpdate {
                        Text("Add a filter server below to get the full lists. Until then the small starter lists bundled with the app are used.")
                    }
                }

                Section {
                    ForEach(store.allowlist, id: \.self) { Text($0) }
                        .onDelete { offsets in
                            let domains = offsets.map { store.allowlist[$0] }
                            Task { await store.disallow(domains) }
                        }
                    HStack {
                        TextField("example.com", text: $newDomain)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.done)
                            .onSubmit(addDomain)
                        Button("Add", action: addDomain)
                            .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Allowed sites")
                } footer: {
                    Text(domainInvalid ? "That doesn't look like a domain." : "Nothing is blocked on these sites or their subdomains.")
                        .foregroundStyle(domainInvalid ? .red : .secondary)
                }

                Section {
                    TextField("https://you.github.io/safari-adblock/", text: $store.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Filter server")
                } footer: {
                    Text("Where tools/build_filters.py output is published (manifest.json plus one file per blocker). Checked about once a day.")
                }
            }
            .navigationTitle("Ad Nope")
            .refreshable { await store.updateFilters(); await store.refreshStates() }
        }
        .task {
            await store.bootstrap()
            await store.refreshStates()
            await store.updateIfStale()
        }
        .onChange(of: scenePhase) { _, phase in
            // Pick up changes made in Settings while the app was in the background.
            if phase == .active { Task { await store.refreshStates() } }
        }
    }

    private func addDomain() {
        let input = newDomain
        Task {
            if await store.allow(input) {
                newDomain = ""
                domainInvalid = false
            } else {
                domainInvalid = true
            }
        }
    }
}

private struct BlockerRow: View {
    let blocker: Blocker
    let status: FilterStore.Status

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: blocker.systemImage)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(blocker.title).font(.headline)
                    Spacer()
                    stateBadge
                }
                Text(blocker.summary).font(.subheadline).foregroundStyle(.secondary)
                if let rules = status.rules {
                    Text(detail(rules: rules))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func detail(rules: Int) -> String {
        let count = "\(rules.formatted()) \(rules == 1 ? "rule" : "rules")"
        guard let updated = status.updated else { return count + " · starter list" }
        return count + " · updated " + updated.formatted(.relative(presentation: .named))
    }

    @ViewBuilder private var stateBadge: some View {
        switch status.enabled {
        case true?: Text("On").badgeStyle(.green)
        case false?: Text("Off in Settings").badgeStyle(.orange)
        case nil: EmptyView()
        }
    }
}

private extension Text {
    func badgeStyle(_ color: Color) -> some View {
        font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
