import AppKit

/// Made-up repos, issues and comments, shown instead of the account's real data when the app
/// is launched with `--demo`. Used for README screenshots; it never calls `gh`.
enum DemoData {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("--demo")

    /// `--demo-window-size 440x820` opens the window at that size, e.g. to capture the compact layout.
    static let windowSize: CGSize? = {
        let args = ProcessInfo.processInfo.arguments
        guard isEnabled, let index = args.firstIndex(of: "--demo-window-size"), index + 1 < args.count else { return nil }
        let parts = args[index + 1].split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }()

    /// SwiftUI sizes the window from its saved split view widths after it opens,
    /// so the demo size is applied once that has settled.
    @MainActor static func applyWindowSize() async {
        guard let windowSize else { return }
        try? await Task.sleep(for: .seconds(1))
        NSApp.windows.first(where: \.canBecomeMain)?.setContentSize(windowSize)
    }
    private static let owner = "acme"

    static let repositories: [RepositoryInfo] = [
        "pixel-pets", "portfolio-site", "recipe-box", "weather-station", "dotfiles",
    ].map { RepositoryInfo(nameWithOwner: "\(owner)/\($0)", hasIssuesEnabled: true) }

    static func items(kind: ItemKind, state: IssueState) -> [Issue] {
        let all = kind == .issues ? issues : pullRequests
        return all.filter { item in
            switch state {
            case .open: item.state == "open"
            case .closed: item.state != "open"
            case .merged: item.state == "merged"
            case .all: true
            }
        }
    }

    static func comments(for issue: Issue) -> [Comment] {
        if let scripted = scriptedComments[issue.number] { return scripted }
        return (0..<issue.commentsCount).map { index in
            let (login, body) = genericComments[index % genericComments.count]
            return comment(id: issue.number * 100 + index, login: login, body: body,
                           hoursAgo: Double(issue.commentsCount - index) * 3, on: issue)
        }
    }

    static func createIssue(repo: String, title: String) -> Issue {
        let number = (issues.filter { $0.repo == repo }.map(\.number).max() ?? 0) + 1
        return item(repo, number, title, labels: [], comments: 0, hoursAgo: 0)
    }

    // MARK: - Content

    private static let label: [String: Issue.IssueLabel] = [
        "bug": .init(name: "bug", color: "d73a4a"),
        "enhancement": .init(name: "enhancement", color: "a2eeef"),
        "design": .init(name: "design", color: "f9c5e8"),
        "good first issue": .init(name: "good first issue", color: "7057ff"),
        "docs": .init(name: "docs", color: "0075ca"),
        "performance": .init(name: "performance", color: "fbca04"),
    ]

    private static let issues: [Issue] = [
        item("weather-station", 42, "Show the hourly forecast as a sparkline",
             labels: ["enhancement", "design"], comments: 2, hoursAgo: 0.4, body: sparklineBody),
        item("weather-station", 41, "Crash when location permission is denied",
             labels: ["bug"], comments: 3, hoursAgo: 2),
        item("recipe-box", 18, "Scale ingredient amounts by number of servings",
             labels: ["enhancement"], comments: 1, hoursAgo: 5),
        item("recipe-box", 17, "Import recipes from a URL",
             labels: ["enhancement"], comments: 0, hoursAgo: 26),
        item("portfolio-site", 9, "Dark mode colors are too low contrast",
             labels: ["bug", "design"], comments: 1, hoursAgo: 30),
        item("pixel-pets", 33, "Pets forget their names after an update",
             labels: ["bug"], comments: 4, hoursAgo: 52),
        item("portfolio-site", 8, "Add an RSS feed for the blog",
             labels: ["enhancement", "good first issue"], comments: 0, hoursAgo: 75),
        item("pixel-pets", 31, "Give the feed button a cooldown",
             labels: ["enhancement"], comments: 2, hoursAgo: 98),
        item("recipe-box", 15, "Write a contributing guide",
             labels: ["docs", "good first issue"], comments: 0, hoursAgo: 140),
        item("weather-station", 40, "Cache API responses for ten minutes",
             labels: ["performance"], comments: 1, hoursAgo: 170),
        item("weather-station", 39, "Wrong units on first launch",
             labels: ["bug"], comments: 2, hoursAgo: 200, state: "closed"),
        item("recipe-box", 14, "Search by ingredient",
             labels: ["enhancement"], comments: 3, hoursAgo: 260, state: "closed"),
    ]

    private static let pullRequests: [Issue] = [
        item("weather-station", 43, "Add the hourly forecast sparkline",
             labels: ["enhancement"], comments: 1, hoursAgo: 0.2, isPullRequest: true),
        item("pixel-pets", 34, "Keep pet names when migrating saved data",
             labels: ["bug"], comments: 0, hoursAgo: 20, isPullRequest: true, isDraft: true),
        item("portfolio-site", 10, "Raise contrast in dark mode",
             labels: ["design"], comments: 2, hoursAgo: 28, isPullRequest: true),
        item("weather-station", 38, "Switch networking to async/await",
             labels: [], comments: 1, hoursAgo: 120, state: "merged", isPullRequest: true),
        item("recipe-box", 19, "Unit conversion helpers",
             labels: ["enhancement"], comments: 0, hoursAgo: 150, state: "merged", isPullRequest: true),
        item("portfolio-site", 7, "Try a serif font for headings",
             labels: ["design"], comments: 3, hoursAgo: 300, state: "closed", isPullRequest: true),
    ]

    private static let sparklineBody = """
        The current-conditions card only shows the next three hours. A small sparkline of the \
        next 24 hours would show at a glance when the rain stops.

        ### What it should do

        - [x] Read the hourly temperatures (already in the API response)
        - [ ] Draw a sparkline under the current temperature
        - [ ] Highlight the current hour
        - [ ] Show the exact value for an hour on hover

        ### Notes

        The forecast already arrives as `hourly.temperature`, so this is UI only.
        """

    private static let scriptedComments: [Int: [Comment]] = {
        guard let issue = issues.first(where: { $0.number == 42 }) else { return [:] }
        return [42: [
            comment(id: 4201, login: "mara", body: "Love this. Let's keep it to temperature for now and add rain later.",
                    hoursAgo: 0.9, association: "OWNER", on: issue),
            comment(id: 4202, login: "theo", body: "Sketched it as a thin line with the current hour as a dot. Picking it up after #41.",
                    hoursAgo: 0.4, association: "CONTRIBUTOR", on: issue),
        ]]
    }()

    private static let genericComments = [
        ("theo", "I can reproduce this on the latest build."),
        ("mara", "Thanks! Let's look at it this week."),
        ("jun", "Would a quick fix be enough here, or does it need a redesign?"),
        ("theo", "Pushed a first pass, feedback welcome."),
    ]

    // MARK: - Builders

    private static func item(
        _ repo: String, _ number: Int, _ title: String, labels: [String], comments: Int, hoursAgo: Double,
        state: String = "open", isPullRequest: Bool = false, isDraft: Bool = false, body: String? = nil
    ) -> Issue {
        let name = "\(owner)/\(repo)"
        let updated = Date.now.addingTimeInterval(-hoursAgo * 3600)
        return Issue(
            number: number, title: title,
            body: body ?? "Spotted while working on \(repo). Details to follow.",
            state: state,
            url: URL(string: "https://github.com/\(name)/\(isPullRequest ? "pull" : "issues")/\(number)")!,
            createdAt: updated.addingTimeInterval(-3 * 86_400), updatedAt: updated,
            commentsCount: comments, author: .init(login: "mara"),
            assignees: number.isMultiple(of: 2) ? [.init(login: "theo")] : [],
            labels: labels.compactMap { label[$0] },
            repository: .init(nameWithOwner: name), isPullRequest: isPullRequest,
            isDraft: isPullRequest ? isDraft : nil
        )
    }

    private static func comment(
        id: Int, login: String, body: String, hoursAgo: Double, association: String = "CONTRIBUTOR", on issue: Issue
    ) -> Comment {
        Comment(
            id: id,
            // An empty data URL: AsyncImage shows its placeholder without touching the network.
            user: .init(login: login, avatarUrl: URL(string: "data:,")!),
            body: body,
            createdAt: Date.now.addingTimeInterval(-hoursAgo * 3600),
            htmlUrl: issue.url,
            authorAssociation: association
        )
    }
}
