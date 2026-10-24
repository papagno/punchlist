import SwiftUI

enum ItemKind: String, CaseIterable, Identifiable {
    case issues = "Issues"
    case pullRequests = "Pull Requests"

    var id: Self { self }

    var searchCommand: String {
        switch self {
        case .issues: "issues"
        case .pullRequests: "prs"
        }
    }

    var noun: String {
        switch self {
        case .issues: "issues"
        case .pullRequests: "pull requests"
        }
    }

    /// The same symbols as the open state badges in the list.
    var symbol: String {
        switch self {
        case .issues: "circle.circle"
        case .pullRequests: "arrow.triangle.pull"
        }
    }
}

enum IssueState: String, CaseIterable, Identifiable {
    case open = "Open"
    case closed = "Closed"
    case merged = "Merged"
    case all = "All"

    var id: Self { self }

    static func options(for kind: ItemKind) -> [IssueState] {
        switch kind {
        case .issues: [.open, .closed, .all]
        case .pullRequests: [.open, .closed, .merged, .all]
        }
    }

    var ghArguments: [String] {
        switch self {
        case .open: ["--state", "open"]
        case .closed: ["--state", "closed"]
        case .merged: ["--merged"]
        case .all: []
        }
    }
}

/// A state change made straight from the list.
enum ItemAction: Hashable {
    case closeIssue(notPlanned: Bool)
    case closePullRequest
    case reopen
    case merge(MergeMethod)

    var failureTitle: String {
        switch self {
        case .closeIssue: "Couldn't close the issue"
        case .closePullRequest: "Couldn't close the pull request"
        case .reopen: "Couldn't reopen"
        case .merge: "Couldn't merge the pull request"
        }
    }

    /// The state GitHub reports once the action has gone through.
    var resultingState: String {
        switch self {
        case .closeIssue, .closePullRequest: "closed"
        case .reopen: "open"
        case .merge: "merged"
        }
    }
}

enum MergeMethod: String, CaseIterable, Identifiable {
    case merge, squash, rebase

    var id: Self { self }

    var title: String {
        switch self {
        case .merge: "Create a Merge Commit"
        case .squash: "Squash and Merge"
        case .rebase: "Rebase and Merge"
        }
    }
}

struct RepositoryInfo: Hashable, Decodable {
    let nameWithOwner: String
    let hasIssuesEnabled: Bool
}

/// An issue or pull request, as returned by `gh search issues|prs`.
struct Issue: Identifiable, Hashable, Decodable {
    struct User: Hashable, Decodable {
        let login: String
    }

    struct IssueLabel: Hashable, Decodable, Identifiable {
        let name: String
        let color: String
        var id: String { name }
    }

    struct Repository: Hashable, Decodable {
        let nameWithOwner: String
    }

    let number: Int
    let title: String
    let body: String
    /// Lowercased: "open", "closed" or, for pull requests, "merged".
    var state: String
    let url: URL
    let createdAt: Date
    let updatedAt: Date
    let commentsCount: Int
    let author: User
    let assignees: [User]
    let labels: [IssueLabel]
    let repository: Repository
    let isPullRequest: Bool
    var isDraft: Bool?

    static func jsonFields(for kind: ItemKind) -> String {
        let common = "number,title,body,state,url,createdAt,updatedAt,commentsCount,author,assignees,labels,repository,isPullRequest"
        return kind == .pullRequests ? common + ",isDraft" : common
    }

    /// The URL is unique across repos and stable across `gh` commands, unlike node ids.
    var id: URL { url }
    var repo: String { repository.nameWithOwner }
    var isOpen: Bool { state.lowercased() == "open" }
    var isMerged: Bool { state.lowercased() == "merged" }
    /// Drafts have to be marked ready for review on GitHub first.
    var canMerge: Bool { isPullRequest && isOpen && isDraft != true }

    var stateBadge: (title: String, symbol: String, color: Color) {
        switch (isPullRequest, state.lowercased()) {
        case (true, "open") where isDraft == true: ("Draft", "arrow.triangle.pull", .gray)
        case (true, "open"): ("Open", "arrow.triangle.pull", .green)
        case (true, "merged"): ("Merged", "arrow.triangle.merge", .purple)
        case (true, _): ("Closed", "xmark.circle", .red)
        case (false, "open"): ("Open", "circle.circle", .green)
        case (false, _): ("Closed", "checkmark.circle", .purple)
        }
    }
}

/// An issue or pull request comment from the REST API (snake_case keys).
struct Comment: Identifiable, Hashable, Decodable {
    struct User: Hashable, Decodable {
        let login: String
        let avatarUrl: URL
    }

    let id: Int
    let user: User
    let body: String
    let createdAt: Date
    let htmlUrl: URL
    let authorAssociation: String

    /// GitHub's badge next to the author, e.g. "Owner"; nil for plain users.
    var associationBadge: String? {
        switch authorAssociation {
        case "OWNER", "MEMBER", "COLLABORATOR", "CONTRIBUTOR": authorAssociation.capitalized
        default: nil
        }
    }
}

extension Color {
    /// Parses GitHub's 6-digit hex label colors.
    init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0x888888
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// The label's own hue, lightened on dark backgrounds and darkened on light ones so it stays
    /// readable on a faint tint of itself: pale labels like a2eeef would vanish on white otherwise.
    static func labelText(hex: String, in colorScheme: ColorScheme) -> Color {
        let color = NSColor(Color(hex: hex)).usingColorSpace(.sRGB) ?? .gray
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return colorScheme == .dark
            ? Color(hue: hue, saturation: min(saturation, 0.45), brightness: max(brightness, 0.8))
            // Grays have no hue to saturate; anything else gets enough color to read as its label.
            : Color(hue: hue, saturation: saturation < 0.1 ? saturation : max(saturation, 0.5), brightness: min(brightness, 0.58))
    }
}
