import MarkdownUI
import SwiftUI

struct IssueDetail: View {
    @Environment(IssuesStore.self) private var store
    let issue: Issue?

    var body: some View {
        if let issue {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(issue.title)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)

                    HStack(spacing: 6) {
                        let badge = issue.stateBadge
                        Label(badge.title, systemImage: badge.symbol)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(badge.color, in: .capsule)
                            .foregroundStyle(.white)
                        Text("\(issue.repo) #\(issue.number) · opened by \(issue.author.login) \(issue.createdAt.formatted(.relative(presentation: .named)))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if !issue.assignees.isEmpty {
                        Text("Assigned to \(issue.assignees.map(\.login).joined(separator: ", "))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if !issue.labels.isEmpty {
                        LabelChips(labels: issue.labels)
                    }

                    Divider()

                    if issue.body.isEmpty {
                        Text("No description provided.")
                            .foregroundStyle(.secondary)
                            .italic()
                    } else {
                        Markdown(issue.body, baseURL: issue.url)
                            .markdownTheme(.issue)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    comments(for: issue)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Keyed on the whole issue so a refresh that bumps updatedAt reloads the comments too.
            .task(id: issue) { await store.loadComments(for: issue) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Open in Browser", systemImage: "safari") {
                        NSWorkspace.shared.open(issue.url)
                    }
                    .help("Open in Browser")
                }
            }
        } else {
            ContentUnavailableView("Select an item", systemImage: "list.bullet.rectangle")
        }
    }

    @ViewBuilder
    private func comments(for issue: Issue) -> some View {
        if let comments = store.comments[issue.id] {
            if !comments.isEmpty {
                Text(comments.count == 1 ? "1 comment" : "\(comments.count) comments")
                    .font(.headline)
                    .padding(.top, 12)
                ForEach(comments) { CommentView(comment: $0, issueURL: issue.url) }
            }
        } else if issue.commentsCount > 0 {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading comments…").foregroundStyle(.secondary)
            }
            .padding(.top, 12)
        }
    }
}

struct CommentView: View {
    let comment: Comment
    let issueURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AsyncImage(url: comment.user.avatarUrl) { image in
                    image.resizable()
                } placeholder: {
                    Color.secondary.opacity(0.2)
                }
                .frame(width: 20, height: 20)
                .clipShape(.circle)
                Text(comment.user.login).fontWeight(.semibold)
                Text(comment.createdAt, format: .relative(presentation: .named))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let badge = comment.associationBadge {
                    Text(badge)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(.separator))
                }
                Link(destination: comment.htmlUrl) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Open comment on GitHub")
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.5))

            Divider()

            Markdown(comment.body, baseURL: issueURL)
                .markdownTheme(.issue)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}

extension Theme {
    /// GitHub's theme, minus its opaque page background.
    static var issue: Theme {
        .gitHub.text {
            ForegroundColor(.primary)
            FontSize(14)
        }
    }
}
