import SwiftUI

/// The issues / pull requests switch and the repo, status and label filters, as two glass sections
/// sized to fit the list column. Search itself is in the toolbar; the filters narrow what the list shows.
struct FilterBar: View {
    /// Shared with the new issue field below, so the bar and the field read as one set.
    static let height: CGFloat = 30

    @Environment(IssuesStore.self) private var store

    var body: some View {
        // One container so the two sections' glass blends where they meet, like toolbar groups.
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                KindSwitch()
                    .frame(maxHeight: .infinity)
                    .glassEffect(.regular, in: .capsule)
                filters
                    .frame(maxHeight: .infinity)
                    .glassEffect(.regular, in: .capsule)
            }
            .frame(height: Self.height)
        }
    }

    private var filters: some View {
        HStack(spacing: 6) {
            repoMenu
            statusMenu.fixedSize()
            labelMenu.fixedSize()
            Spacer(minLength: 0)
            moreMenu.fixedSize()
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.visible)
        .padding(.horizontal, 10)
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
            // A text title, not a symbol: symbols inside Text aren't drawn in a pull-down's title.
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

/// Two icon buttons with a capsule that slides to the selected one, concentric with the glass
/// around it; a segmented picker's rounded rectangle doesn't fit inside a capsule.
private struct KindSwitch: View {
    @Environment(IssuesStore.self) private var store
    @Environment(\.appearsActive) private var appearsActive
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ItemKind.allCases) { kind in
                let isSelected = store.kind == kind
                Button {
                    withAnimation(.snappy(duration: 0.25)) { store.kind = kind }
                } label: {
                    Image(systemName: kind.symbol)
                        .frame(width: 32)
                        .frame(maxHeight: .infinity)
                        .foregroundStyle(isSelected && appearsActive ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(appearsActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                                    .matchedGeometryEffect(id: "selection", in: selection)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .help(kind.rawValue)
                .accessibilityLabel(kind.rawValue)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show")
    }
}
