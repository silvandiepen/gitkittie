import Foundation
import GitKittieKit
import GitPontCore

/// The offline demo: one small repository held in memory, served through the same GitPont
/// provider contract as GitHub or GitLab. Every commit is a full snapshot of the files, so
/// history, diffs, reading files at a commit, and making a branch, a commit and a pull
/// request all work for real against it — for trying the app without an account, for App
/// Review, and for screenshots.
actor DemoStore {
    struct Commit {
        var summary: GitCommitSummary
        var files: [String: String]
    }

    static let repository = GitRepositoryReference(
        instance: .github, namespace: "harbor", name: "website", defaultBranch: "main",
        webURL: URL(string: "https://github.com/harbor/website"))

    private var commits: [String: Commit] = [:]
    private var branches: [String: String] = [:]
    private var pulls: [GitPullRequest] = []
    private var counter = 0

    init() {
        let (commits, branches, pulls) = DemoStore.seed()
        self.commits = commits
        self.branches = branches
        self.pulls = pulls
    }

    // MARK: Reading

    func branchList() -> [GitPontCore.GitBranch] {
        branches.keys.sorted { $0 == "main" ? true : ($1 == "main" ? false : $0 < $1) }.map {
            GitPontCore.GitBranch(name: $0, commitSHA: branches[$0]!, isDefault: $0 == "main", isProtected: $0 == "main")
        }
    }

    /// Newest first, following first parents from the ref.
    func history(ref: String?, path: String?) throws -> [GitCommitSummary] {
        guard var sha = try resolve(ref) else { return [] }
        var result: [GitCommitSummary] = []
        while let commit = commits[sha] {
            let parent = commit.summary.parentSHAs.first.flatMap { commits[$0] }
            if let path {
                if commit.files[path] != parent?.files[path] { result.append(commit.summary) }
            } else {
                result.append(commit.summary)
            }
            guard let next = commit.summary.parentSHAs.first else { break }
            sha = next
        }
        return result
    }

    func detail(sha: String) throws -> GitCommitDetail {
        guard let commit = commits[sha] else { throw GitPontError.notFound("No commit \(sha)") }
        let parentFiles = commit.summary.parentSHAs.first.flatMap { commits[$0]?.files } ?? [:]
        let paths = Set(parentFiles.keys).union(commit.files.keys).sorted()
        let files: [GitCommitFileChange] = paths.compactMap { path in
            let old = parentFiles[path]
            let new = commit.files[path]
            guard old != new else { return nil }
            let hunks = GitDiffWriter.hunks(from: old, to: new)
            let counts = GitUnifiedDiff.lineCounts(of: hunks)
            return GitCommitFileChange(
                path: path,
                status: old == nil ? .added : (new == nil ? .removed : .modified),
                additions: counts.additions,
                deletions: counts.deletions,
                patch: hunks.isEmpty ? nil : hunks)
        }
        return GitCommitDetail(summary: commit.summary, files: files)
    }

    func file(path: String, ref: String) throws -> String? {
        guard let sha = try resolve(ref) else { return nil }
        return commits[sha]?.files[path]
    }

    func directory(path: String, ref: String) throws -> [GitDirectoryEntry] {
        guard let sha = try resolve(ref), let files = commits[sha]?.files else { return [] }
        let prefix = path.isEmpty ? "" : path + "/"
        var seen = Set<String>()
        var entries: [GitDirectoryEntry] = []
        for file in files.keys.sorted() where file.hasPrefix(prefix) {
            let rest = file.dropFirst(prefix.count)
            let name = String(rest.split(separator: "/").first ?? Substring(rest))
            guard seen.insert(name).inserted else { continue }
            let isDirectory = rest.contains("/")
            entries.append(GitDirectoryEntry(name: name, path: prefix + name, type: isDirectory ? .directory : .file))
        }
        return entries
    }

    func pullRequestList(filter: GitPullRequestListQuery.Filter) -> [GitPullRequest] {
        pulls.filter {
            switch filter {
            case .all: return true
            case .open: return $0.state == .open
            case .closed: return $0.state != .open
            }
        }.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    // MARK: Writing

    func createBranch(name: String, from ref: String) throws -> GitPontCore.GitBranch {
        guard branches[name] == nil else { throw GitPontError.invalidProviderResponse("A branch named \(name) already exists") }
        guard let sha = try resolve(ref) else { throw GitPontError.notFound("No branch or commit \(ref)") }
        branches[name] = sha
        return GitPontCore.GitBranch(name: name, commitSHA: sha)
    }

    func commit(_ request: GitMultiFileCommit) throws -> GitCommitResult {
        guard let head = branches[request.branch], let parent = commits[head] else {
            throw GitPontError.notFound("No branch \(request.branch)")
        }
        var files = parent.files
        for operation in request.operations {
            files[operation.path] = operation.content.map { String(decoding: $0, as: UTF8.self) }
        }
        counter += 1
        let sha = String(format: "%040x", 0xD3_0000 + counter)
        commits[sha] = Commit(
            summary: GitCommitSummary(sha: sha, message: request.message, authorName: "You", authoredAt: Date(), parentSHAs: [head]),
            files: files)
        branches[request.branch] = sha
        return GitCommitResult(commitSHA: sha, branch: request.branch)
    }

    func openPullRequest(_ request: GitPullRequestRequest) -> GitPullRequest {
        let number = (pulls.compactMap(\.number).max() ?? 0) + 1
        let pull = GitPullRequest(
            id: String(number), number: number, title: request.title,
            webURL: URL(string: "https://github.com/harbor/website/pull/\(number)")!,
            sourceBranch: request.sourceBranch, targetBranch: request.targetBranch, providerName: "GitHub",
            state: .open, authorName: "You", body: request.body, isDraft: request.draft,
            createdAt: Date(), updatedAt: Date())
        pulls.append(pull)
        return pull
    }

    private func resolve(_ ref: String?) throws -> String? {
        let name = ref ?? "main"
        if let sha = branches[name] { return sha }
        if commits[name] != nil { return name }
        if let match = commits.keys.first(where: { $0.hasPrefix(name) && name.count >= 7 }) { return match }
        return nil
    }

    // MARK: Seed

    private static func seed() -> ([String: Commit], [String: String], [GitPullRequest]) {
        var commits: [String: Commit] = [:]
        var files: [String: String] = [:]
        var head: String?
        var number = 0
        let calendar = Calendar(identifier: .gregorian)
        let base = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9))!

        func commit(_ message: String, by author: String, day: Int, parents extra: [String] = [], _ change: (inout [String: String]) -> Void) -> String {
            change(&files)
            number += 1
            let sha = String(format: "%07x", 0xA1B2C30 + number * 7919) + String(repeating: "0", count: 33)
            let date = base.addingTimeInterval(TimeInterval(day * 86_400 + number * 3_700))
            commits[sha] = Commit(
                summary: GitCommitSummary(
                    sha: sha, message: message, authorName: author, authorEmail: nil, authoredAt: date,
                    parentSHAs: (head.map { [$0] } ?? []) + extra,
                    webURL: URL(string: "https://github.com/harbor/website/commit/\(sha)")),
                files: files)
            head = sha
            return sha
        }

        _ = commit("chore: scaffold the site", by: "Mara Chen", day: 0) {
            $0["index.html"] = DemoText.index
            $0["styles.css"] = DemoText.styles
            $0["README.md"] = "# Harbor\n\nThe marketing site for Harbor.\n\n## Develop\n\nOpen index.html in a browser.\n"
        }
        _ = commit("feat: add the pricing section", by: "Mara Chen", day: 2) {
            $0["index.html"] = $0["index.html"]!.replacingOccurrences(of: "  </main>", with: """
                <section id="pricing">
                  <h2>Pricing</h2>
                  <p>Free for teams of up to five. Then $8 per person, per month.</p>
                </section>
              </main>
            """)
            $0["styles.css"]! += "\n#pricing {\n  border-top: 1px solid #e3e7ee;\n  padding-top: 32px;\n}\n"
        }
        _ = commit("feat: follow the system dark mode\n\nUses prefers-color-scheme, so nothing to switch.", by: "Alex Rivera", day: 4) {
            $0["styles.css"]! += "\n@media (prefers-color-scheme: dark) {\n  body {\n    background: #0b101b;\n    color: #e8ecf4;\n  }\n}\n"
        }
        let mixed = commit("Update header, docs and add analytics", by: "Mara Chen", day: 8) {
            $0["index.html"] = $0["index.html"]!
                .replacingOccurrences(of: "      <a href=\"#pricing\">Pricing</a>\n", with: "      <a href=\"#pricing\">Pricing</a>\n      <a href=\"/docs\">Docs</a>\n      <a class=\"button\" href=\"/signup\">Start free</a>\n")
                .replacingOccurrences(of: "</body>", with: "  <script defer src=\"https://plausible.io/js/script.js\" data-domain=\"harbor.dev\"></script>\n</body>")
            $0["README.md"] = $0["README.md"]!.replacingOccurrences(of: "Open index.html in a browser.", with: "Open `index.html` in a browser, or run `npx serve .` for live reload.")
            $0["styles.css"]! += "\n.button {\n  padding: 8px 14px;\n  border-radius: 999px;\n  background: #2f6be8;\n  color: #fff;\n}\n"
        }
        _ = mixed
        // A branch with work in review, cut before the year fix went in on main.
        let branchPoint = (files, head)
        let feature = commit("feat: add a testimonials section", by: "Alex Rivera", day: 9) {
            $0["index.html"] = $0["index.html"]!.replacingOccurrences(of: "  </main>", with: """
                <section id="testimonials">
                  <blockquote>“Release day stopped being a fire drill.” — Ops lead, Northwind</blockquote>
                </section>
              </main>
            """)
        }
        (files, head) = branchPoint
        let main = commit("fix: correct the footer year", by: "Mara Chen", day: 10) {
            $0["index.html"] = $0["index.html"]!.replacingOccurrences(of: "© 2025 Harbor", with: "© 2026 Harbor")
        }

        let branches = ["main": main, "feature/testimonials": feature]
        let day: (Int) -> Date = { base.addingTimeInterval(TimeInterval($0 * 86_400)) }
        let pulls = [
            GitPullRequest(
                id: "12", number: 12, title: "Add a testimonials section",
                webURL: URL(string: "https://github.com/harbor/website/pull/12")!,
                sourceBranch: "feature/testimonials", targetBranch: "main", providerName: "GitHub",
                state: .open, authorName: "alex", body: "One quote for now; more once legal has signed them off.",
                createdAt: day(11), updatedAt: day(12)),
            GitPullRequest(
                id: "9", number: 9, title: "Follow the system dark mode",
                webURL: URL(string: "https://github.com/harbor/website/pull/9")!,
                sourceBranch: "feature/dark-mode", targetBranch: "main", providerName: "GitHub",
                state: .merged, authorName: "alex", body: "Uses prefers-color-scheme, so there is nothing to switch.",
                createdAt: day(4), updatedAt: day(5)),
        ]
        return (commits, branches, pulls)
    }
}

private enum DemoText {
    static let index = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>Harbor</title>
      <link rel="stylesheet" href="styles.css">
    </head>
    <body>
      <header class="site-header">
        <a class="logo" href="/">Harbor</a>
        <nav>
          <a href="#features">Features</a>
          <a href="#pricing">Pricing</a>
        </nav>
      </header>
      <main>
        <h1>Ship calmer releases</h1>
        <p>Harbor keeps every release note, changelog and rollout in one place.</p>
      </main>
      <footer>© 2025 Harbor</footer>
    </body>
    </html>

    """

    static let styles = """
    body {
      margin: 0;
      font-family: system-ui, sans-serif;
      color: #1d2330;
    }

    .site-header {
      display: flex;
      justify-content: space-between;
      padding: 16px 24px;
    }

    """
}

/// The demo store behind GitPont's provider contract.
struct DemoProvider: GitProvider {
    let store: DemoStore

    var kind: GitProviderKind { .github }
    var displayName: String { "Demo" }
    var capabilities: GitProviderCapabilities {
        [.publicFileRead, .authenticatedFileRead, .directoryList, .batchCommit, .branchCreate, .pullRequestCreate, .commitHistory, .pullRequestList]
    }
    var changeRequestTerm: GitChangeRequestTerm { .pullRequest }

    func canHandle(url: URL) -> Bool { false }
    func parse(url: URL) throws -> GitURLParseResult { throw GitPontError.unsupportedURL(url.absoluteString) }

    func account(instance: GitProviderInstance, credential: GitCredential) async throws -> GitAccount {
        GitAccount(id: "demo", login: "demo")
    }

    func repositories(context: GitProviderRequestContext) async throws -> GitList<GitRepository> {
        GitList(items: [GitRepository(
            reference: DemoStore.repository, description: "The marketing site for Harbor", isPrivate: false, isFork: false,
            permissions: GitRepositoryPermissions(canRead: true, canPush: true, canAdmin: false),
            updatedAt: Date())])
    }

    func repository(_ reference: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitRepository {
        try await repositories(context: context).items[0]
    }

    func branches(repository: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitList<GitPontCore.GitBranch> {
        GitList(items: await store.branchList())
    }

    func readFile(_ reference: GitFileReference, context: GitProviderRequestContext) async throws -> GitRemoteFile {
        guard let text = try await store.file(path: reference.path, ref: reference.ref) else {
            throw GitPontError.notFound(reference.path)
        }
        return GitRemoteFile(reference: reference, content: Data(text.utf8), encoding: .utf8)
    }

    func listDirectory(_ reference: GitFileReference, context: GitProviderRequestContext) async throws -> GitList<GitDirectoryEntry> {
        GitList(items: try await store.directory(path: reference.path, ref: reference.ref))
    }

    func commitFile(_ change: GitFileChange, context: GitProviderRequestContext) async throws -> GitCommitResult {
        try await store.commit(GitMultiFileCommit(
            repository: change.reference.repository, branch: change.targetBranch, message: change.message,
            operations: [.write(change.reference.path, change.content)]))
    }

    func deleteFile(_ request: GitFileDeleteRequest, context: GitProviderRequestContext) async throws -> GitCommitResult {
        try await store.commit(GitMultiFileCommit(
            repository: request.reference.repository, branch: request.reference.ref, message: request.message,
            operations: [.delete(request.reference.path)]))
    }

    func commitFiles(_ commit: GitMultiFileCommit, context: GitProviderRequestContext) async throws -> GitCommitResult {
        try await store.commit(commit)
    }

    func createBranch(_ request: GitCreateBranchRequest, context: GitProviderRequestContext) async throws -> GitPontCore.GitBranch {
        try await store.createBranch(name: request.name, from: request.fromRef)
    }

    func deleteBranch(_ request: GitDeleteBranchRequest, context: GitProviderRequestContext) async throws {
        throw GitPontError.unsupportedCapability("deleteBranch")
    }

    func createRepository(_ request: GitCreateRepositoryRequest, context: GitProviderRequestContext) async throws -> GitRepository {
        throw GitPontError.unsupportedCapability("createRepository")
    }

    func forkRepository(_ reference: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitRepository {
        throw GitPontError.unsupportedCapability("forkRepository")
    }

    func createPullRequest(_ request: GitPullRequestRequest, context: GitProviderRequestContext) async throws -> GitPullRequest {
        await store.openPullRequest(request)
    }

    func commits(_ query: GitCommitHistoryQuery, context: GitProviderRequestContext) async throws -> GitList<GitCommitSummary> {
        let all = try await store.history(ref: query.ref, path: query.path)
        let start = (query.page - 1) * query.perPage
        guard start < all.count else { return GitList(items: []) }
        let end = min(all.count, start + query.perPage)
        return GitList(items: Array(all[start..<end]), truncated: end < all.count)
    }

    func commit(sha: String, repository: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitCommitDetail {
        try await store.detail(sha: sha)
    }

    func pullRequests(_ query: GitPullRequestListQuery, context: GitProviderRequestContext) async throws -> GitList<GitPullRequest> {
        GitList(items: await store.pullRequestList(filter: query.filter))
    }
}
