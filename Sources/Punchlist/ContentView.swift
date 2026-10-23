import SwiftUI

struct ContentView: View {
    /// Below this width the window behaves like an iPhone: list only, detail pushed on top.
    nonisolated static let compactWidth: CGFloat = 640

    @Environment(IssuesStore.self) private var store
    @State private var width: CGFloat = 1000
    @FocusState private var isSearchFocused: Bool

    private var isCompact: Bool { width < Self.compactWidth }

    var body: some View {
        @Bindable var store = store

        Group {
            if isCompact { compactLayout } else { wideLayout }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: isCompact, initial: true) { store.isCompact = isCompact }
        .task(id: store.query) { await store.load() }
        .task(id: store.query.includeOrgs) { await store.loadRepositories() }
        // Search lives at the trailing edge of the toolbar, per the HIG for split-view apps.
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search \(store.kind.noun)")
        .searchFocused($isSearchFocused)
        .onChange(of: store.wantsSearchFocus) {
            guard store.wantsSearchFocus else { return }
            isSearchFocused = true
            store.wantsSearchFocus = false
        }
        .toolbar {
            if isCompact, store.selectedIssue != nil {
                ToolbarItem(placement: .navigation) {
                    Button("Back", systemImage: "chevron.backward", action: pop)
                        .help("Back to the list")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                // The arrow spins while loading instead of being swapped for a spinner,
                // which would resize the item's glass capsule.
                Button("Refresh", systemImage: "arrow.clockwise") {
                    guard !store.isLoading else { return }
                    Task { await store.load() }
                }
                .symbolEffect(.rotate.byLayer, options: .repeat(.continuous), isActive: store.isLoading)
                .help(store.isLoading ? "Loading…" : "Refresh")
            }
        }
        // A short title naming what's shown, not the app (HIG: Toolbars > Titles).
        .navigationTitle(store.kind.rawValue)
        .navigationSubtitle(subtitle)
    }

    /// The system split view: a resizable, collapsible glass sidebar with the list, detail beside it.
    private var wideLayout: some View {
        @Bindable var store = store
        return NavigationSplitView {
            Sidebar(selection: $store.selection)
                .navigationSplitViewColumnWidth(min: 300, ideal: 400, max: 640)
        } detail: {
            IssueDetail(issue: store.selectedIssue)
        }
    }

    /// The list fills the window; the detail slides in over it from the trailing edge.
    private var compactLayout: some View {
        @Bindable var store = store
        return ZStack {
            Sidebar(selection: $store.selection, onOpen: push)
                .offset(x: store.selectedIssue == nil ? 0 : -width / 4)

            if let selectedIssue = store.selectedIssue {
                IssueDetail(issue: selectedIssue)
                    .background(.background)
                    .shadow(color: .black.opacity(0.25), radius: 10)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .clipped()
        .onExitCommand { if store.selectedIssue != nil { pop() } }
    }

    private func push(_ issue: Issue) {
        // Otherwise the focused field's focus ring stays drawn on top of the pushed detail.
        NSApp.keyWindow?.makeFirstResponder(nil)
        withAnimation(.smooth(duration: 0.3)) { store.selection = issue.id }
    }

    private func pop() {
        withAnimation(.smooth(duration: 0.3)) { store.selection = nil }
    }

    private var subtitle: String {
        if isCompact, let selectedIssue = store.selectedIssue {
            return "\(selectedIssue.repo) #\(selectedIssue.number)"
        }
        let shown = store.filteredIssues.count
        let total = store.issues.count
        let noun = store.kind.noun
        return shown == total ? "\(total) \(noun)" : "\(shown) of \(total) \(noun)"
    }
}

/// The list column: the issues / pull requests switch and the filters on top, then the rows.
struct Sidebar: View {
    @Environment(IssuesStore.self) private var store
    @Binding var selection: Issue.ID?
    /// Set in the compact layout: clicking a row opens it instead of selecting it.
    var onOpen: ((Issue) -> Void)?

    var body: some View {
        Group {
            if let onOpen {
                List { rows(onOpen: onOpen) }
            } else {
                List(selection: $selection) { rows(onOpen: nil) }
                    .contextMenu(forSelectionType: Issue.ID.self) { ids in
                        if let issue = store.issue(id: ids.first) { ItemActions(issue: issue) }
                    } primaryAction: { ids in
                        if let issue = store.issue(id: ids.first) { NSWorkspace.shared.open(issue.url) }
                    }
            }
        }
        // A bar rather than a stacked header, so rows scroll under it with the system edge effect.
        .safeAreaBar(edge: .top) { header }
    }

    private var header: some View {
        @Bindable var store = store
        return VStack(spacing: 8) {
            Picker("Show", selection: $store.kind) {
                ForEach(ItemKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            FilterBar()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func rows(onOpen: ((Issue) -> Void)?) -> some View {
        if store.kind == .issues {
            NewIssueRow { issue in
                if let onOpen { onOpen(issue) } else { selection = issue.id }
            }
        }
        if store.filteredIssues.isEmpty {
            placeholder
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
        } else if let onOpen {
            ForEach(store.filteredIssues) { issue in
                IssueRow(issue: issue, showsDisclosure: true)
                    .contentShape(.rect)
                    .onTapGesture { onOpen(issue) }
                    .contextMenu { ItemActions(issue: issue) }
            }
        } else {
            ForEach(store.filteredIssues) { IssueRow(issue: $0) }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if store.isLoading {
            ProgressView("Loading \(store.kind.noun)…")
                .controlSize(.small)
                .padding(.vertical, 40)
        } else if let error = store.errorMessage {
            ContentUnavailableView {
                Label("Couldn't load \(store.kind.noun)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).textSelection(.enabled)
            } actions: {
                Button("Try Again") { Task { await store.load() } }
            }
        } else {
            ContentUnavailableView {
                Label("No \(store.kind.noun)", systemImage: "checkmark.circle")
            } description: {
                if let filters = store.activeFilterSummary {
                    Text("None of the \(store.issues.count) \(store.kind.noun) match \(filters).")
                } else {
                    Text("Nothing to see here.")
                }
            } actions: {
                if store.hasLocalFilters {
                    Button("Clear Filters") { store.clearLocalFilters() }
                }
            }
        }
    }
}

/// The per-item commands, shared by the context menu and the menu bar's item menu.
struct ItemActions: View {
    @Environment(IssuesStore.self) private var store
    let issue: Issue

    var body: some View {
        Button("Open in Browser") { NSWorkspace.shared.open(issue.url) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(issue.url.absoluteString, forType: .string)
        }
        Divider()
        Button("Show Only \(issue.repo)") { store.repoFilter = issue.repo }
    }
}

struct IssueRow: View {
    let issue: Issue
    var showsDisclosure = false

    var body: some View {
        HStack(spacing: 8) {
            content
            if showsDisclosure {
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            let badge = issue.stateBadge
            Image(systemName: badge.symbol)
                .foregroundStyle(badge.color)
                .help(badge.title)
                .accessibilityLabel(badge.title)
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text("\(issue.repo) #\(issue.number)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("·")
                        .accessibilityHidden(true)
                    Text(issue.updatedAt, format: .relative(presentation: .named))
                        .lineLimit(1)
                    if issue.commentsCount > 0 {
                        Label("\(issue.commentsCount)", systemImage: "bubble.left")
                            .labelStyle(.titleAndIcon)
                            .accessibilityLabel(issue.commentsCount == 1 ? "1 comment" : "\(issue.commentsCount) comments")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !issue.labels.isEmpty {
                    LabelChips(labels: issue.labels)
                }
            }
        }
    }
}

struct LabelChips: View {
    let labels: [Issue.IssueLabel]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(labels) { label in
                Text(label.name)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color(hex: label.color), in: .capsule)
                    .foregroundStyle(Color.labelText(onHex: label.color))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Labels: \(labels.map(\.name).joined(separator: ", "))")
    }
}
