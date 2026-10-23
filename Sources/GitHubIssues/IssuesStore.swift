import Foundation
import Observation

@MainActor
@Observable
final class IssuesStore {
    /// Changing any of these needs a fresh `gh search`; the other filters apply locally.
    struct Query: Hashable {
        var kind: ItemKind = .issues
        var state: IssueState = .open
        var includeOrgs = false
    }

    var query = Query()
    var selection: Issue.ID?
    var repoFilter: String?
    var labelFilter: Set<String> = []
    var searchText = ""

    private(set) var issues: [Issue] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastUpdated: Date?
    /// All of the owners' repos, shared by both tabs so the repo filter means the same thing in each.
    private(set) var allRepositories: [RepositoryInfo] = []
    /// Last results per query, so switching tabs never shows the other tab's rows.
    private var cache: [Query: [Issue]] = [:]
    private(set) var comments: [Issue.ID: [Comment]] = [:]

    /// Set by the window: below the compact width the detail is pushed over the list.
    var isCompact = false
    /// One-shot focus requests from menu commands, consumed by the views that own the fields.
    var wantsNewIssueFocus = false
    var wantsSearchFocus = false

    var kind: ItemKind {
        get { query.kind }
        set {
            guard newValue != query.kind else { return }
            query.kind = newValue
            selection = nil
            if !IssueState.options(for: newValue).contains(query.state) { query.state = .open }
        }
    }

    var hasLocalFilters: Bool {
        repoFilter != nil || !labelFilter.isEmpty || !searchText.isEmpty
    }

    /// Plain-language description of the local filters, e.g. `repo a/b and label "bug"`.
    var activeFilterSummary: String? {
        var parts: [String] = []
        if let repoFilter { parts.append("repo \(repoFilter)") }
        if !labelFilter.isEmpty {
            let names = labelFilter.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
            parts.append(labelFilter.count == 1 ? "label \(names)" : "labels \(names)")
        }
        if !searchText.isEmpty { parts.append("\"\(searchText)\"") }
        return parts.isEmpty ? nil : parts.joined(separator: " and ")
    }

    /// Where new issues can be created.
    var issueRepositories: [String] {
        allRepositories.filter(\.hasIssuesEnabled).map(\.nameWithOwner)
    }

    /// How many loaded items each repo has in the current tab.
    var itemCounts: [String: Int] {
        issues.reduce(into: [:]) { $0[$1.repo, default: 0] += 1 }
    }

    /// Every repo the filter can pick, the same list in both tabs.
    var repositories: [String] {
        var names = Set(allRepositories.map(\.nameWithOwner)).union(issues.map(\.repo))
        if let repoFilter { names.insert(repoFilter) }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Labels on the issues in scope (respecting the repo filter), plus any already selected.
    var labels: [Issue.IssueLabel] {
        var byName: [String: Issue.IssueLabel] = [:]
        for issue in issues where repoFilter == nil || issue.repo == repoFilter {
            for label in issue.labels { byName[label.name] = label }
        }
        for name in labelFilter where byName[name] == nil {
            byName[name] = Issue.IssueLabel(name: name, color: "888888")
        }
        return byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var filteredIssues: [Issue] {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        return issues.filter { issue in
            if let repoFilter, issue.repo != repoFilter { return false }
            if !labelFilter.isEmpty, !labelFilter.isSubset(of: issue.labels.map(\.name)) { return false }
            if !text.isEmpty {
                let haystack = "\(issue.title) \(issue.repo) #\(issue.number) \(issue.author.login)"
                if !haystack.localizedCaseInsensitiveContains(text) { return false }
            }
            return true
        }
    }

    var selectedIssue: Issue? { issue(id: selection) }

    /// File > New Issue: back to the issues list with the new-issue field focused.
    func requestNewIssue() {
        kind = .issues
        if isCompact { selection = nil }
        wantsNewIssueFocus = true
    }

    func issue(id: Issue.ID?) -> Issue? {
        guard let id else { return nil }
        return issues.first { $0.id == id }
    }

    func clearLocalFilters() {
        repoFilter = nil
        labelFilter = []
        searchText = ""
    }

    func load() async {
        let query = query
        issues = cache[query] ?? []
        isLoading = true
        errorMessage = nil
        do {
            let owners = try await GH.owners(includeOrgs: query.includeOrgs)
            let result = try await GH.search(query.kind, owners: owners, state: query.state)
            cache[query] = result
            // A newer query may have started while gh was running.
            guard !Task.isCancelled, query == self.query else { return }
            issues = result
            lastUpdated = .now
        } catch {
            guard !Task.isCancelled, query == self.query else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func loadComments(for issue: Issue) async {
        guard let loaded = try? await GH.comments(for: issue) else { return }
        comments[issue.id] = loaded
    }

    func loadRepositories() async {
        guard let owners = try? await GH.owners(includeOrgs: query.includeOrgs),
              let repos = try? await GH.repositories(owners: owners) else { return }
        allRepositories = repos
    }

    /// Creates the issue and shows it straight away; search results lag behind by a few seconds.
    func createIssue(repo: String, title: String) async throws -> Issue {
        let issue = try await GH.createIssue(repo: repo, title: title)
        if query.kind == .issues, query.state != .closed {
            issues.insert(issue, at: 0)
            cache[query] = issues
        }
        return issue
    }
}
