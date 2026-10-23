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
    /// Items with a close, reopen or merge still running.
    private(set) var busyItems: Set<Issue.ID> = []
    /// Set to ask which way to merge; the window shows the dialog with `mergeMethods`.
    var mergeCandidate: Issue?
    private(set) var mergeMethods = MergeMethod.allCases
    private var allowedMergeMethods: [String: [MergeMethod]] = [:]
    /// States set from the list, laid over search results until the search index catches up.
    private var confirmedStates: [Issue.ID: (state: String, at: Date)] = [:]
    var actionFailure: (title: String, message: String)?

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
            var result: [Issue]
            if DemoData.isEnabled {
                result = DemoData.items(kind: query.kind, state: query.state)
            } else {
                let owners = try await GH.owners(includeOrgs: query.includeOrgs)
                result = try await GH.search(query.kind, owners: owners, state: query.state)
            }
            applyConfirmedStates(to: &result)
            cache[query] = result
            // A newer query may have started while gh was running.
            guard !Task.isCancelled, query == self.query else { return }
            issues = result
            lastUpdated = .now
            // The demo opens on an item so screenshots show the detail too, unless it was given
            // a window size (for the compact layout, where that would hide the list).
            if DemoData.isEnabled, DemoData.windowSize == nil, selection == nil { selection = result.first?.id }
        } catch {
            guard !Task.isCancelled, query == self.query else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func loadComments(for issue: Issue) async {
        if DemoData.isEnabled {
            comments[issue.id] = DemoData.comments(for: issue)
            return
        }
        guard let loaded = try? await GH.comments(for: issue) else { return }
        comments[issue.id] = loaded
    }

    func loadRepositories() async {
        if DemoData.isEnabled {
            allRepositories = DemoData.repositories
            return
        }
        guard let owners = try? await GH.owners(includeOrgs: query.includeOrgs),
              let repos = try? await GH.repositories(owners: owners) else { return }
        allRepositories = repos
    }

    /// Creates the issue and shows it straight away; search results lag behind by a few seconds.
    func createIssue(repo: String, title: String) async throws -> Issue {
        let issue = DemoData.isEnabled
            ? DemoData.createIssue(repo: repo, title: title)
            : try await GH.createIssue(repo: repo, title: title)
        if query.kind == .issues, query.state != .closed {
            issues.insert(issue, at: 0)
            cache[query] = issues
        }
        return issue
    }

    /// Asks which way to merge, offering only the methods the repo allows.
    func requestMerge(_ pullRequest: Issue) async {
        if allowedMergeMethods[pullRequest.repo] == nil, !DemoData.isEnabled {
            guard busyItems.insert(pullRequest.id).inserted else { return }
            allowedMergeMethods[pullRequest.repo] = try? await GH.mergeMethods(repo: pullRequest.repo)
            busyItems.remove(pullRequest.id)
        }
        mergeMethods = allowedMergeMethods[pullRequest.repo] ?? MergeMethod.allCases
        mergeCandidate = pullRequest
    }

    /// Closes, reopens or merges the item in place. It stays in the list, with its new state,
    /// until the next refresh, so a slip can be undone from the same row.
    func perform(_ action: ItemAction, on item: Issue) async {
        guard busyItems.insert(item.id).inserted else { return }
        defer { busyItems.remove(item.id) }
        do {
            let state = DemoData.isEnabled ? action.resultingState : try await GH.perform(action, on: item)
            // A merge that was only queued leaves the PR open; later searches should show it merging.
            if state == action.resultingState { confirmedStates[item.id] = (state, .now) }
            updateState(of: item.id, to: state)
        } catch {
            actionFailure = (action.failureTitle, error.localizedDescription)
        }
    }

    /// Search can report the old state for a while after a change; a few minutes covers it
    /// without hiding a later change made on GitHub for good.
    private func applyConfirmedStates(to items: inout [Issue]) {
        confirmedStates = confirmedStates.filter { $0.value.at.timeIntervalSinceNow > -300 }
        for index in items.indices {
            guard let confirmed = confirmedStates[items[index].id] else { continue }
            if items[index].state == confirmed.state {
                confirmedStates[items[index].id] = nil
            } else {
                items[index].state = confirmed.state
            }
        }
    }

    private func updateState(of id: Issue.ID, to state: String) {
        if let index = issues.firstIndex(where: { $0.id == id }) { issues[index].state = state }
        for (query, items) in cache {
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            cache[query]?[index].state = state
        }
    }
}
