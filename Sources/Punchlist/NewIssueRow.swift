import SwiftUI

/// First row of the issues list: type a title, pick a repo, press Return. The issue is listed
/// at once and saved in the background, so the next one can be typed straight away.
struct NewIssueRow: View {
    @Environment(IssuesStore.self) private var store
    @AppStorage("newIssueRepository") private var lastRepository = ""
    @State private var title = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.tint)
                TextField("New issue title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit(create)
            }
            // On its own line so the field keeps its width in a narrow sidebar.
            repositoryMenu
                .padding(.leading, 26)
        }
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
            Text("in \(repository ?? "…")")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
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
                .foregroundStyle(isSaving ? Color.secondary : Color.red)
                .symbolEffect(.pulse, options: .repeat(.continuous), isActive: isSaving)
                .accessibilityLabel(isSaving ? "Saving" : "Couldn't save")
            VStack(alignment: .leading, spacing: 4) {
                Text(pending.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(isSaving ? .secondary : .primary)
                Text(isSaving ? "\(pending.repo) · Saving…" : pending.repo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        .padding(.vertical, 3)
    }
}
