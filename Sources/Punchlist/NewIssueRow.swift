import SwiftUI

/// First row of the issues list: type a title, pick a repo, press Return.
struct NewIssueRow: View {
    @Environment(IssuesStore.self) private var store
    @AppStorage("newIssueRepository") private var lastRepository = ""
    @State private var title = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    let onCreated: (Issue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if isCreating {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.tint)
                }
                TextField("New issue title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .disabled(isCreating)
                    .onSubmit(create)
            }
            // On its own line so the field keeps its width in a narrow sidebar.
            repositoryMenu
                .padding(.leading, 26)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
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
        .disabled(store.repoFilter != nil || isCreating)
        .help(store.repoFilter != nil ? "Uses the repo filter" : "Repository for the new issue")
    }

    private func create() {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let repository, !isCreating else { return }
        isCreating = true
        errorMessage = nil
        Task {
            defer { isCreating = false }
            do {
                let issue = try await store.createIssue(repo: repository, title: title)
                self.title = ""
                onCreated(issue)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
