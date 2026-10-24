import SwiftUI

/// First row of the issues list: type a title, pick a repo, press Return. The issue is listed
/// at once and saved in the background, so the next one can be typed straight away.
struct NewIssueRow: View {
    @Environment(IssuesStore.self) private var store
    @AppStorage("newIssueRepository") private var lastRepository = ""
    @State private var title = ""
    @FocusState private var isFocused: Bool
    private static let fieldInset: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A glass capsule like the toolbar's search field, rather than a bezeled box.
            TextField("New issue title", text: $title, prompt: Text(""))
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit(create)
                // Drawn here rather than as the prompt: on the sidebar's glass the field's own
                // placeholder is as bright as typed text.
                .background(alignment: .leading) {
                    if title.isEmpty {
                        Text("New issue")
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, Self.fieldInset)
                .frame(height: FilterBar.height)
                // Clicks on the capsule around the text focus the field too.
                .contentShape(.capsule)
                .onTapGesture { isFocused = true }
                .glassEffect(.regular.interactive(), in: .capsule)
                .overlay {
                    // Plain fields draw no focus ring, so the capsule shows focus itself.
                    Capsule()
                        .strokeBorder(.tint, lineWidth: 2)
                        .opacity(isFocused ? 0.6 : 0)
                }
                .animation(.easeOut(duration: 0.15), value: isFocused)
            // On its own line so the field keeps its width in a narrow sidebar; lined up with its text.
            repositoryMenu
                .padding(.leading, Self.fieldInset)
        }
        // List rows are inset 4pt more than the filter bar above; this lines the capsules up.
        .padding(.horizontal, -4)
        .padding(.vertical, 4)
        // Runs on appear too, so File > New Issue works even when it had to switch tabs first.
        .task(id: store.wantsNewIssueFocus) {
            guard store.wantsNewIssueFocus else { return }
            isFocused = true
            store.wantsNewIssueFocus = false
        }
    }

    /// The repo filter wins, then the last repo used, then the first one available.
    private var repository: String? {
        store.repoFilter
            ?? (lastRepository.isEmpty ? nil : lastRepository)
            ?? store.issueRepositories.first
    }

    private var repositoryMenu: some View {
        Menu {
            ForEach(store.issueRepositories, id: \.self) { repo in
                Button(repo) { lastRepository = repo }
            }
        } label: {
            HStack(spacing: 3) {
                Text("in \(repository ?? "…")")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .fontWeight(.semibold)
                    .accessibilityHidden(true)
            }
            .font(.callout)
            .contentShape(.rect)
        }
        // A plain button, so SwiftUI draws the label: the AppKit pull-down styles draw their arrow
        // black in the sidebar list, even in dark mode, and ignore the secondary color.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .disabled(store.repoFilter != nil)
        .help(store.repoFilter != nil ? "Uses the repo filter" : "Repository for the new issue")
    }

    private func create() {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let repository else { return }
        store.submitIssue(repo: repository, title: title)
        self.title = ""
    }
}

/// A new issue while it's saved; if saving failed, the error with Retry and Discard.
struct PendingIssueRow: View {
    @Environment(IssuesStore.self) private var store
    let pending: IssuesStore.PendingIssue

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            let isSaving = pending.errorMessage == nil
            // Pulses like a row whose state is changing, without changing the row's layout.
            Image(systemName: isSaving ? "circle.circle" : "exclamationmark.triangle.fill")
                .font(IssueRow.titleFont)
                .frame(width: IssueRow.iconWidth)
                .foregroundStyle(isSaving ? Color.secondary : Color.red)
                .symbolEffect(.pulse, options: .repeat(.continuous), isActive: isSaving)
                .accessibilityLabel(isSaving ? "Saving" : "Couldn't save")
            VStack(alignment: .leading, spacing: 2) {
                Text(pending.title)
                    .font(IssueRow.titleFont)
                    .lineLimit(2)
                    .foregroundStyle(isSaving ? .secondary : .primary)
                // The repo is left out while the list shows only that one, like the issue rows.
                let repo = store.repoFilter == nil ? pending.repo : nil
                if let details = isSaving ? [repo, "Saving…"].compactMap(\.self).joined(separator: " · ") : repo {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let errorMessage = pending.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    HStack {
                        Button("Retry") { store.retry(pending.id) }
                        Button("Discard") { store.discard(pending.id) }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
