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

    /// A new issue the list shows while `gh` saves it, or after saving failed.
    struct PendingIssue: Identifiable {
        let id = UUID()
        let repo: String
        let title: String
        /// Set once GitHub has created it, so a retry only reads it back instead of creating it twice.
        var url: URL?
        var errorMessage: String?
    }

    /// Results younger than this are shown without searching again; Refresh always searches.
    private static let freshness: TimeInterval = 120
    /// How long changes made here are laid over search results, which lag behind.
    private static let searchLag: TimeInterval = 300

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
    /// Last results per query and when they arrived, so switching tabs is instant and never
    /// shows the other tab's rows.
    private var cache: [Query: (items: [Issue], at: Date)] = [:]
    /// Searches still running, so a prefetch and a switch to that tab share one `gh search`.
    private var searches: [Query: Task<[Issue], any Error>] = [:]
    /// New issues saving in the background, newest first.
    private(set) var pendingIssues: [PendingIssue] = []
    private(set) var comments: [Issue.ID: [Comment]] = [:]
    /// Items with a close, reopen or merge still running.
    private(set) var busyItems: Set<Issue.ID> = []
    /// Set to ask which way to merge; the window shows the dialog with `mergeMethods`.
    var mergeCandidate: Issue?
    private(set) var mergeMethods = MergeMethod.allCases
    private var allowedMergeMethods: [String: [MergeMethod]] = [:]
    /// States set and issues created from the list, laid over search results until the
    /// search index catches up.
    private var confirmedStates: [Issue.ID: (state: String, at: Date)] = [:]
    private var createdIssues: [(issue: Issue, at: Date)] = []
    /// The signed-in user, from the last search; tells their own repos from their orgs'.
    private var login: String?
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

    /// Whether the current tab has been searched at least once; until then it shows a spinner.
    var hasResults: Bool { cache[query] != nil }

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

    /// Shows the last results straight away, then searches again unless they're recent.
    func load(force: Bool = false) async {
        let query = query
        let cached = cache[query]
        issues = cached?.items ?? []
        errorMessage = nil
        if !force, let cached, cached.at.timeIntervalSinceNow > -Self.freshness {
            lastUpdated = cached.at
            isLoading = false
            selectFirstForDemo()
            return
        }
        isLoading = true
        do {
            let result = try await search(query)
            // A newer query may have started while gh was running.
            guard !Task.isCancelled, query == self.query else { return }
            // The cache, not `result`: a save or state change may have landed since the search.
            issues = cache[query]?.items ?? result
            lastUpdated = .now
            selectFirstForDemo()
        } catch {
            guard !Task.isCancelled, query == self.query else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// The demo opens on an item so screenshots show the detail too, unless it was given
    /// a window size (for the compact layout, where that would hide the list).
    private func selectFirstForDemo() {
        if DemoData.isEnabled, DemoData.windowSize == nil, selection == nil { selection = issues.first?.id }
    }

    /// Searches the other tab in the background, so the first switch to it is instant too.
    func prefetchOtherTab() async {
        var other = query
        other.kind = query.kind == .issues ? .pullRequests : .issues
        if !IssueState.options(for: other.kind).contains(other.state) { other.state = .open }
        if let cached = cache[other], cached.at.timeIntervalSinceNow > -Self.freshness { return }
        _ = try? await search(other)
    }

    /// Runs the query's search, or joins the one already running, and caches the results.
    private func search(_ query: Query) async throws -> [Issue] {
        if let running = searches[query] { return try await running.value }
        let search = Task {
            defer { searches[query] = nil }
            var result: [Issue]
            if DemoData.isEnabled {
                result = DemoData.items(kind: query.kind, state: query.state)
            } else {
                let owners = try await GH.owners(includeOrgs: query.includeOrgs)
                login = owners.first
                result = try await GH.search(query.kind, owners: owners, state: query.state)
            }
            applyRecentChanges(to: &result, for: query, fromSearch: true)
            cache[query] = (result, .now)
            return result
        }
        searches[query] = search
        return try await search.value
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

    /// Lists the issue straight away and saves it in the background; a failure stays in the
    /// list with Retry.
    func submitIssue(repo: String, title: String) {
        let pending = PendingIssue(repo: repo, title: title)
        pendingIssues.insert(pending, at: 0)
        Task { await save(pending.id) }
    }

    func retry(_ id: PendingIssue.ID) {
        guard let index = pendingIssues.firstIndex(where: { $0.id == id }),
              pendingIssues[index].errorMessage != nil else { return }
        pendingIssues[index].errorMessage = nil
        Task { await save(id) }
    }

    func discard(_ id: PendingIssue.ID) {
        pendingIssues.removeAll { $0.id == id }
    }

    private func save(_ id: PendingIssue.ID) async {
        guard let pending = pendingIssues.first(where: { $0.id == id }) else { return }
        do {
            let issue: Issue
            if DemoData.isEnabled {
                issue = DemoData.createIssue(repo: pending.repo, title: pending.title)
            } else {
                let url: URL
                if let created = pending.url {
                    url = created
                } else {
                    url = try await GH.createIssue(repo: pending.repo, title: pending.title)
                    if let index = pendingIssues.firstIndex(where: { $0.id == id }) { pendingIssues[index].url = url }
                }
                issue = try await GH.issue(at: url, repo: pending.repo)
            }
            pendingIssues.removeAll { $0.id == id }
            createdIssues.append((issue, .now))
            for query in cache.keys { applyRecentChanges(to: &cache[query]!.items, for: query, fromSearch: false) }
            // A tab still waiting for its first results gets the issue when they arrive.
            if let cached = cache[query] { issues = cached.items }
        } catch {
            guard let index = pendingIssues.firstIndex(where: { $0.id == id }) else { return }
            // Discarding and retyping it then would make a duplicate.
            pendingIssues[index].errorMessage = pendingIssues[index].url == nil
                ? error.localizedDescription
                : "Created on GitHub, but couldn't load it: \(error.localizedDescription)"
        }
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
            // Otherwise a new issue closed straight away would be put back in the open list.
            createdIssues.removeAll { $0.issue.id == item.id }
            updateState(of: item, to: state)
        } catch {
            actionFailure = (action.failureTitle, error.localizedDescription)
        }
    }

    /// Search can miss a new issue or report an old state for a while after a change; a few
    /// minutes covers it without hiding a later change made on GitHub for good. Only fresh
    /// search results (`fromSearch`) show that search has caught up with a change, so only
    /// they let it go; the cached lists already have the changes laid over them.
    private func applyRecentChanges(to items: inout [Issue], for query: Query, fromSearch: Bool) {
        createdIssues = createdIssues.filter { $0.at.timeIntervalSinceNow > -Self.searchLag }
        if query.kind == .issues, query.state != .closed {
            let found = Set(items.map(\.id))
            if fromSearch { createdIssues.removeAll { found.contains($0.issue.id) } }
            // Without orgs, searches only cover the user's own repos.
            let missing = createdIssues.map(\.issue).filter { created in
                !found.contains(created.id)
                    && (query.includeOrgs || login.map { created.repo.hasPrefix("\($0)/") } ?? true)
            }
            items.insert(contentsOf: missing.reversed(), at: 0)
        }

        confirmedStates = confirmedStates.filter { $0.value.at.timeIntervalSinceNow > -Self.searchLag }
        for index in items.indices {
            guard let confirmed = confirmedStates[items[index].id] else { continue }
            if items[index].state != confirmed.state {
                items[index].state = confirmed.state
            } else if fromSearch {
                confirmedStates[items[index].id] = nil
            }
        }
    }

    /// Updates the item wherever it's cached. The tab's other lists, such as Closed after a
    /// close, may be missing it, so they search again next time instead of counting as fresh.
    private func updateState(of item: Issue, to state: String) {
        if let index = issues.firstIndex(where: { $0.id == item.id }) { issues[index].state = state }
        let kind: ItemKind = item.isPullRequest ? .pullRequests : .issues
        for (query, cached) in cache where query.kind == kind {
            if let index = cached.items.firstIndex(where: { $0.id == item.id }) {
                cache[query]?.items[index].state = state
            } else {
                cache[query]?.at = .distantPast
            }
        }
    }
}
