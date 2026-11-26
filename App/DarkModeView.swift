import SwiftUI

/// Extras › Dark mode for websites.
struct DarkModeView: View {
    @State private var settings = DarkModeSettings.load()
    @State private var newSite = ""
    @State private var siteInvalid = false

    var body: some View {
        Form {
            Section {
                Toggle("Dark mode for websites", isOn: $settings.enabled)
                Picker("Use it", selection: $settings.when) {
                    ForEach(DarkModeSettings.When.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!settings.enabled)
            } footer: {
                Text("Gives light-only websites a dark look by inverting their colors. Photos and videos keep their real colors, and sites that are already dark are left alone. Changes apply when you reload a page.")
            }

            Section {
                ForEach(settings.excluded, id: \.self) { site in
                    Text(site).contextMenu {
                        Button("Remove", role: .destructive) { settings.excluded.removeAll { $0 == site } }
                    }
                }
                .onDelete { settings.excluded.remove(atOffsets: $0) }
                HStack {
                    TextField("example.com", text: $newSite)
                        .urlEntry()
                        .onSubmit(addSite)
                    Button("Add", action: addSite)
                        .disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Never darken")
            } footer: {
                Text(siteInvalid ? "That doesn't look like a domain." : "For sites that look wrong inverted.")
                    .foregroundStyle(siteInvalid ? .red : .secondary)
            }

            Section {
                ForEach(Array(Self.setupSteps.enumerated()), id: \.offset) { i, step in
                    Label {
                        Text(step)
                    } icon: {
                        Text("\(i + 1)").font(.callout.monospacedDigit().weight(.semibold))
                    }
                }
            } header: {
                Text("Turn it on in Safari")
            } footer: {
                Text("Unlike the blockers, this extension needs permission to change web pages so it can recolor them. It runs only inside Safari and doesn't send anything anywhere.")
            }
        }
        .navigationTitle("Dark Mode")
        .onChange(of: settings) { _, new in new.save() }
    }

    private func addSite() {
        guard let domain = Allowlist.normalize(newSite) else {
            siteInvalid = true
            return
        }
        if !settings.excluded.contains(domain) {
            settings.excluded.append(domain)
            settings.excluded.sort()
        }
        newSite = ""
        siteInvalid = false
    }

    #if os(macOS)
    private static let setupSteps = [
        "Open Safari › Settings › Extensions.",
        "Turn on Ad Nope Dark.",
        "Under Websites, set Ad Nope Dark to Allow for all websites.",
    ]
    #else
    private static let setupSteps = [
        "Open Settings › Apps › Safari › Extensions › Ad Nope Dark.",
        "Turn on Allow Extension.",
        "Under Permissions, set All Websites to Allow.",
    ]
    #endif
}
