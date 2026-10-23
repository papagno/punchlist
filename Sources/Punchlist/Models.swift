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

    static func labelText(onHex hex: String) -> Color {
        let value = UInt64(hex, radix: 16) ?? 0x888888
        let r = Double((value >> 16) & 0xFF), g = Double((value >> 8) & 0xFF), b = Double(value & 0xFF)
        let luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255
        return luminance > 0.6 ? .black : .white
    }
}
