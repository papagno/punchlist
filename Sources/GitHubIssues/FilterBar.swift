import SwiftUI

/// Repo, status and label filters as compact pull-down buttons, sized to fit the list column.
/// Search itself is in the toolbar; these narrow what the list shows.
struct FilterBar: View {
    @Environment(IssuesStore.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            repoMenu
            statusMenu.fixedSize()
            labelMenu.fixedSize()
            Spacer(minLength: 0)
            moreMenu.fixedSize()
        }
        .controlSize(.small)
    }

    private var repoMenu: some View {
        @Bindable var store = store
        let counts = store.itemCounts
        let withItems = store.repositories.filter { counts[$0] != nil }
        let others = store.repositories.filter { counts[$0] == nil }
        return Menu {
            Picker("Repository", selection: $store.repoFilter) {
                Text("All Repositories").tag(String?.none)
                Section("With \(store.kind.noun)") {
                    ForEach(withItems, id: \.self) { repo in
                        Text("\(repo) (\(counts[repo] ?? 0))").tag(Optional(repo))
                    }
                }
                Section("No \(store.kind.noun)") {
                    ForEach(others, id: \.self) { repo in
                        Text(repo).tag(Optional(repo))
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(store.repoFilter.map(Self.shortName) ?? "All Repositories")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(store.repoFilter ?? "Filter by repository")
    }

    private var statusMenu: some View {
        @Bindable var store = store
        return Menu {
            Picker("Status", selection: $store.query.state) {
                ForEach(IssueState.options(for: store.kind)) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(store.query.state.rawValue)
        }
        .help("Filter by status")
    }

    private var labelMenu: some View {
        Menu {
            if store.labels.isEmpty {
                Text("No Labels")
            }
            ForEach(store.labels) { label in
                Toggle(label.name, isOn: Binding(
                    get: { store.labelFilter.contains(label.name) },
                    set: { isOn in
                        if isOn { store.labelFilter.insert(label.name) } else { store.labelFilter.remove(label.name) }
                    }
                ))
            }
            if !store.labelFilter.isEmpty {
                Divider()
                Button("Clear Labels") { store.labelFilter = [] }
            }
        } label: {
            Text(labelMenuTitle)
        }
        .help("Filter by label")
    }

    private var moreMenu: some View {
        @Bindable var store = store
        return Menu {
            Toggle("Include Organizations", isOn: $store.query.includeOrgs)
            Divider()
            Button("Clear Filters") { store.clearLocalFilters() }
                .disabled(!store.hasLocalFilters)
        } label: {
            // A text title, not a symbol: an icon-only pull-down gets a smaller bezel than its
            // text-titled neighbors, and symbols inside Text aren't drawn in a pull-down's title.
            Text("⋯")
                .accessibilityLabel("More Filters")
        }
        .menuIndicator(.hidden)
        .help("More filters")
    }

    private var labelMenuTitle: String {
        switch store.labelFilter.count {
        case 0: "Labels"
        case 1: store.labelFilter.first!
        default: "\(store.labelFilter.count) Labels"
        }
    }

    /// "owner/name" → "name"; the menu itself shows the full name.
    private static func shortName(_ repo: String) -> String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }
}
