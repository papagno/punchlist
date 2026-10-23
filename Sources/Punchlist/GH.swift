import Foundation

/// Thin wrapper around the installed `gh` CLI.
enum GH {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// GUI apps don't inherit the shell's PATH, so look in the usual install locations
    /// before asking a login shell.
    static let executable: URL? = {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        if let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(filePath: path)
        }
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v gh"]
        let out = Pipe()
        shell.standardOutput = out
        guard (try? shell.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(filePath: path)
    }()

    static func run(_ arguments: [String]) async throws -> Data {
        guard let executable else {
            throw Failure(message: "Couldn't find the gh CLI. Install it with `brew install gh` and run `gh auth login`.")
        }
        return try await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
            env["GH_PROMPT_DISABLED"] = "1"
            env["NO_COLOR"] = "1"
            process.environment = env

            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure(message: message.isEmpty ? "gh exited with status \(process.terminationStatus)" : message)
            }
            return data
        }.value
    }

    static func lines(_ arguments: [String]) async throws -> [String] {
        let data = try await run(arguments)
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    /// The authenticated user's login followed by the orgs they belong to.
    static func owners(includeOrgs: Bool) async throws -> [String] {
        let login = try await lines(["api", "user", "-q", ".login"])
        guard includeOrgs else { return login }
        let orgs = try await lines(["api", "user/orgs", "--paginate", "-q", ".[].login"])
        return login + orgs
    }

    static func search(_ kind: ItemKind, owners: [String], state: IssueState) async throws -> [Issue] {
        var args = ["search", kind.searchCommand, "--archived=false", "--sort", "updated", "--limit", "1000",
                    "--json", Issue.jsonFields(for: kind)]
        for owner in owners { args += ["--owner", owner] }
        args += state.ghArguments
        return try decoder.decode([Issue].self, from: await run(args))
    }

    /// Every non-archived repo the owners have, whether or not anything is open in it.
    static func repositories(owners: [String]) async throws -> [RepositoryInfo] {
        var repos: [RepositoryInfo] = []
        for owner in owners {
            let data = try await run(["repo", "list", owner, "--no-archived", "--limit", "1000",
                                      "--json", "nameWithOwner,hasIssuesEnabled"])
            repos += try decoder.decode([RepositoryInfo].self, from: data)
        }
        return repos.sorted { $0.nameWithOwner.localizedStandardCompare($1.nameWithOwner) == .orderedAscending }
    }

    /// Creates the issue and returns its URL; `issue(at:repo:)` reads it back.
    static func createIssue(repo: String, title: String) async throws -> URL {
        let created = try await lines(["issue", "create", "--repo", repo, "--title", title, "--body", ""])
        guard let line = created.last(where: { $0.hasPrefix("https://") }), let url = URL(string: line) else {
            throw Failure(message: "gh didn't return the new issue's URL.")
        }
        return url
    }

    static func issue(at url: URL, repo: String) async throws -> Issue {
        // `gh issue view` uses different field names from `gh search`, so map it by hand.
        struct Viewed: Decodable {
            let number: Int
            let title: String
            let body: String
            let state: String
            let url: URL
            let createdAt: Date
            let updatedAt: Date
            let author: Issue.User
            let assignees: [Issue.User]
            let labels: [Issue.IssueLabel]
        }
        let data = try await run(["issue", "view", url.absoluteString, "--json",
                                  "number,title,body,state,url,createdAt,updatedAt,author,assignees,labels"])
        let viewed = try decoder.decode(Viewed.self, from: data)
        return Issue(
            number: viewed.number, title: viewed.title, body: viewed.body, state: viewed.state.lowercased(),
            url: viewed.url, createdAt: viewed.createdAt, updatedAt: viewed.updatedAt, commentsCount: 0,
            author: viewed.author, assignees: viewed.assignees, labels: viewed.labels,
            repository: .init(nameWithOwner: repo), isPullRequest: false
        )
    }

    /// Runs the action and returns the item's state afterwards, as GitHub reports it: merging
    /// into a branch with a merge queue only queues the pull request, so it can stay open.
    static func perform(_ action: ItemAction, on item: Issue) async throws -> String {
        let command = item.isPullRequest ? "pr" : "issue"
        let url = item.url.absoluteString
        switch action {
        case .closeIssue(let notPlanned):
            _ = try await run(["issue", "close", url, "--reason", notPlanned ? "not planned" : "completed"])
        case .closePullRequest:
            _ = try await run(["pr", "close", url])
        case .reopen:
            _ = try await run([command, "reopen", url])
        case .merge(let method):
            _ = try await run(["pr", "merge", url, "--\(method.rawValue)"])
        }
        // The change has gone through either way, so a failed read-back isn't reported.
        struct Viewed: Decodable { let state: String }
        guard let data = try? await run([command, "view", url, "--json", "state"]),
              let viewed = try? decoder.decode(Viewed.self, from: data) else { return action.resultingState }
        return viewed.state.lowercased()
    }

    /// The merge methods the repo allows; GitHub refuses the others.
    static func mergeMethods(repo: String) async throws -> [MergeMethod] {
        struct Settings: Decodable {
            let mergeCommitAllowed: Bool
            let squashMergeAllowed: Bool
            let rebaseMergeAllowed: Bool
        }
        let data = try await run(["repo", "view", repo, "--json",
                                  "mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed"])
        let settings = try decoder.decode(Settings.self, from: data)
        return MergeMethod.allCases.filter { method in
            switch method {
            case .merge: settings.mergeCommitAllowed
            case .squash: settings.squashMergeAllowed
            case .rebase: settings.rebaseMergeAllowed
            }
        }
    }

    /// Conversation comments; the issues endpoint serves pull requests too.
    static func comments(for issue: Issue) async throws -> [Comment] {
        let data = try await run(["api", "repos/\(issue.repo)/issues/\(issue.number)/comments",
                                  "--paginate", "--slurp"])
        let decoder = decoder
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([[Comment]].self, from: data).flatMap(\.self)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
