import Foundation

public struct GitCommitNode: Sendable, Identifiable, Equatable {
    public let id: String
    public let shortID: String
    public let parentIDs: [String]
    public let decorations: [String]
    public let author: String
    public let authorDate: Date
    public let subject: String
    public let body: String

    public init(
        id: String,
        shortID: String,
        parentIDs: [String],
        decorations: [String],
        author: String,
        authorDate: Date,
        subject: String,
        body: String
    ) {
        self.id = id
        self.shortID = shortID
        self.parentIDs = parentIDs
        self.decorations = decorations
        self.author = author
        self.authorDate = authorDate
        self.subject = subject
        self.body = body
    }
}

public struct GitChangedFile: Sendable, Identifiable, Equatable {
    public let id: String
    public let status: String
    public let path: String
    public let oldPath: String?

    public init(status: String, path: String, oldPath: String? = nil) {
        self.status = status
        self.path = path
        self.oldPath = oldPath
        self.id = oldPath.map { "\($0)->\(path)" } ?? path
    }
}

public struct GitHunk: Sendable, Identifiable, Equatable {
    public let id: String
    public let header: String
    public let lines: [String]

    public init(id: String, header: String, lines: [String]) {
        self.id = id
        self.header = header
        self.lines = lines
    }
}

public struct GitFileDiff: Sendable, Identifiable, Equatable {
    public let id: String
    public let oldPath: String?
    public let path: String
    public let hunks: [GitHunk]

    public init(path: String, oldPath: String? = nil, hunks: [GitHunk]) {
        self.path = path
        self.oldPath = oldPath
        self.hunks = hunks
        self.id = oldPath.map { "\($0)->\(path)" } ?? path
    }
}

public struct GitBlameLine: Sendable, Identifiable, Equatable {
    public let lineNumber: Int
    public let commitID: String
    public let shortCommitID: String
    public let author: String
    public let summary: String
    public let content: String

    public var id: Int { lineNumber }

    public init(lineNumber: Int, commitID: String, shortCommitID: String, author: String, summary: String, content: String) {
        self.lineNumber = lineNumber
        self.commitID = commitID
        self.shortCommitID = shortCommitID
        self.author = author
        self.summary = summary
        self.content = content
    }
}

public struct GitReflogEntry: Sendable, Identifiable, Equatable {
    public let id: String
    public let commitID: String
    public let shortCommitID: String
    public let selector: String
    public let subject: String
    public let author: String
    public let date: Date?
    public let dateDescription: String

    public init(
        commitID: String,
        shortCommitID: String,
        selector: String,
        subject: String,
        author: String,
        date: Date?,
        dateDescription: String
    ) {
        self.commitID = commitID
        self.shortCommitID = shortCommitID
        self.selector = selector
        self.subject = subject
        self.author = author
        self.date = date
        self.dateDescription = dateDescription
        self.id = "\(selector)-\(commitID)"
    }
}

public enum GitHistorySearchMode: String, Sendable, CaseIterable, Equatable {
    case message
    case changes
}

public struct GitBranchSummary: Sendable, Equatable {
    public let currentBranch: String?
    public let upstream: String?
    public let ahead: Int
    public let behind: Int

    public init(currentBranch: String?, upstream: String?, ahead: Int, behind: Int) {
        self.currentBranch = currentBranch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
    }
}

public struct GitRemote: Sendable, Identifiable, Equatable {
    public let name: String
    public let fetchURL: String?
    public let pushURL: String?

    public var id: String { name }

    public init(name: String, fetchURL: String?, pushURL: String?) {
        self.name = name
        self.fetchURL = fetchURL
        self.pushURL = pushURL
    }
}

public struct GitProtectedBranchPolicy: Sendable, Equatable {
    public var patterns: [String]

    public init(patterns: [String] = ["main", "master", "development", "release/*"]) {
        self.patterns = patterns
    }

    public func protects(_ branch: String?) -> Bool {
        guard let branch, !branch.isEmpty else { return false }
        return patterns.contains { pattern in
            Self.matches(pattern: pattern, branch: branch)
        }
    }

    private static func matches(pattern: String, branch: String) -> Bool {
        if pattern == branch { return true }
        guard pattern.contains("*") else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
        return branch.range(of: "^\(escaped)$", options: .regularExpression) != nil
    }
}

public struct GitBranch: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case local
        case remote
    }

    public let id: String
    public let name: String
    public let shortName: String
    public let kind: Kind
    public let commitID: String
    public let shortCommitID: String
    public let subject: String
    public let updatedAt: Date?
    public let updatedDescription: String
    public let isCurrent: Bool
    public let upstream: String?

    public init(
        name: String,
        shortName: String,
        kind: Kind,
        commitID: String,
        shortCommitID: String,
        subject: String,
        updatedAt: Date? = nil,
        updatedDescription: String = "",
        isCurrent: Bool,
        upstream: String? = nil
    ) {
        self.id = name
        self.name = name
        self.shortName = shortName
        self.kind = kind
        self.commitID = commitID
        self.shortCommitID = shortCommitID
        self.subject = subject
        self.updatedAt = updatedAt
        self.updatedDescription = updatedDescription
        self.isCurrent = isCurrent
        self.upstream = upstream
    }
}

public struct GitTag: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let commitID: String
    public let shortCommitID: String
    public let subject: String

    public init(name: String, commitID: String, shortCommitID: String, subject: String) {
        self.id = name
        self.name = name
        self.commitID = commitID
        self.shortCommitID = shortCommitID
        self.subject = subject
    }
}

public struct GitWorktreeFile: Sendable, Identifiable, Equatable {
    public let id: String
    public let path: String
    public let indexStatus: String
    public let workingTreeStatus: String
    public let originalPath: String?

    public init(path: String, indexStatus: String, workingTreeStatus: String, originalPath: String? = nil) {
        self.id = originalPath.map { "\($0)->\(path)" } ?? path
        self.path = path
        self.indexStatus = indexStatus
        self.workingTreeStatus = workingTreeStatus
        self.originalPath = originalPath
    }

    public var isStaged: Bool {
        indexStatus != " " && indexStatus != "?"
    }

    public var hasWorkingTreeChanges: Bool {
        workingTreeStatus != " "
    }

    public var displayStatus: String {
        if isStaged && hasWorkingTreeChanges {
            return "\(indexStatus)\(workingTreeStatus)"
        }
        if isStaged {
            return indexStatus
        }
        return workingTreeStatus
    }
}

public struct GitLinkedWorktree: Sendable, Identifiable, Equatable {
    public let id: String
    public let path: String
    public let head: String?
    public let branch: String?
    public let isCurrent: Bool

    public init(path: String, head: String?, branch: String?, isCurrent: Bool) {
        self.id = path
        self.path = path
        self.head = head
        self.branch = branch
        self.isCurrent = isCurrent
    }
}

public struct GitSubmodule: Sendable, Identifiable, Equatable {
    public enum State: String, Sendable, Equatable {
        case initialized
        case uninitialized
        case changed
        case conflicted
    }

    public let id: String
    public let path: String
    public let commitID: String
    public let state: State
    public let details: String?

    public init(path: String, commitID: String, state: State, details: String?) {
        self.id = path
        self.path = path
        self.commitID = commitID
        self.state = state
        self.details = details
    }
}

public struct GitStashEntry: Sendable, Identifiable, Equatable {
    public let id: String
    public let index: Int
    public let branch: String?
    public let message: String

    public init(id: String, index: Int, branch: String?, message: String) {
        self.id = id
        self.index = index
        self.branch = branch
        self.message = message
    }
}

public struct GitBranchOperationResult: Sendable, Equatable {
    public let completed: Bool
    public let conflicts: [GitFileConflict]

    public init(completed: Bool, conflicts: [GitFileConflict] = []) {
        self.completed = completed
        self.conflicts = conflicts
    }
}

public struct GitBranchFlow: Sendable, Equatable {
    public let currentBranch: String
    public let targetBranch: String
    public let mergeBaseID: String
    public let mergeBaseShortID: String
    public let mergeBaseSubject: String
    public let currentOnlyCommits: [GitRewritePreviewItem]
    public let targetOnlyCommits: [GitRewritePreviewItem]
    public let changedFiles: [GitChangedFile]

    public init(
        currentBranch: String,
        targetBranch: String,
        mergeBaseID: String,
        mergeBaseShortID: String,
        mergeBaseSubject: String,
        currentOnlyCommits: [GitRewritePreviewItem],
        targetOnlyCommits: [GitRewritePreviewItem],
        changedFiles: [GitChangedFile] = []
    ) {
        self.currentBranch = currentBranch
        self.targetBranch = targetBranch
        self.mergeBaseID = mergeBaseID
        self.mergeBaseShortID = mergeBaseShortID
        self.mergeBaseSubject = mergeBaseSubject
        self.currentOnlyCommits = currentOnlyCommits
        self.targetOnlyCommits = targetOnlyCommits
        self.changedFiles = changedFiles
    }

    public var currentAheadCount: Int { currentOnlyCommits.count }
    public var targetAheadCount: Int { targetOnlyCommits.count }
    public var changedFileCount: Int { changedFiles.count }
}

public struct GitRewritePreviewItem: Sendable, Identifiable, Equatable {
    public let id: String
    public let shortID: String
    public let subject: String
    public let currentIndex: Int?
    public let plannedIndex: Int

    public init(id: String, shortID: String, subject: String, currentIndex: Int?, plannedIndex: Int) {
        self.id = id
        self.shortID = shortID
        self.subject = subject
        self.currentIndex = currentIndex
        self.plannedIndex = plannedIndex
    }
}

public struct GitRewritePreview: Sendable, Equatable {
    public let baseCommitID: String
    public let currentOldestToNewest: [GitRewritePreviewItem]
    public let plannedOldestToNewest: [GitRewritePreviewItem]

    public init(
        baseCommitID: String,
        currentOldestToNewest: [GitRewritePreviewItem],
        plannedOldestToNewest: [GitRewritePreviewItem]
    ) {
        self.baseCommitID = baseCommitID
        self.currentOldestToNewest = currentOldestToNewest
        self.plannedOldestToNewest = plannedOldestToNewest
    }
}

public struct GitPurgePreview: Sendable, Equatable {
    public let paths: [String]
    public let affectedCommits: [GitRewritePreviewItem]
    public let affectedBranches: [String]
    public let affectedTags: [String]
    public let repositorySizeBytes: Int64?

    public init(
        paths: [String],
        affectedCommits: [GitRewritePreviewItem],
        affectedBranches: [String],
        affectedTags: [String],
        repositorySizeBytes: Int64?
    ) {
        self.paths = paths
        self.affectedCommits = affectedCommits
        self.affectedBranches = affectedBranches
        self.affectedTags = affectedTags
        self.repositorySizeBytes = repositorySizeBytes
    }

    public var affectedCommitCount: Int { affectedCommits.count }
}

public enum GitConflictSide: String, Sendable, Equatable {
    case yourChange = "Your change"
    case remoteChange = "REmote change"
}

public struct GitConflictSection: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let side: GitConflictSide
    public let lines: [String]

    public init(id: UUID = UUID(), side: GitConflictSide, lines: [String]) {
        self.id = id
        self.side = side
        self.lines = lines
    }
}

public struct GitFileConflict: Sendable, Identifiable, Equatable {
    public let id: String
    public let path: String
    public let sections: [GitConflictSection]

    public init(path: String, sections: [GitConflictSection]) {
        self.id = path
        self.path = path
        self.sections = sections
    }
}

public enum GitRewriteConflictMode: Sendable, Equatable {
    case merge
    case rebase
    case revert
    case cherryPick
    case stashPop
}

public enum GitRewriteResolution: Sendable, Equatable {
    case yourChange
    case remoteChange
}

public enum GitRewriteError: LocalizedError, Sendable {
    case dirtyWorkingTree
    case notEnoughCommits
    case emptySelection
    case nothingLeftAfterSplit
    case noCurrentBranch
    case noUpstream
    case invalidBranchName(String)
    case invalidTagName(String)
    case unsupportedCommit(String)

    public var errorDescription: String? {
        switch self {
        case .dirtyWorkingTree:
            return "The working tree must be clean before rewriting history."
        case .notEnoughCommits:
            return "There are not enough commits for that rewrite."
        case .emptySelection:
            return "Select at least one file or hunk."
        case .nothingLeftAfterSplit:
            return "All changes moved into the new commit; there is no remaining commit to create."
        case .noCurrentBranch:
            return "A current branch is required for this operation."
        case .noUpstream:
            return "An upstream branch is required for this operation."
        case let .invalidBranchName(name):
            return "\(name) is not a valid branch name."
        case let .invalidTagName(name):
            return "\(name) is not a valid tag name."
        case let .unsupportedCommit(commit):
            return "This rewrite currently supports HEAD only, not \(commit)."
        }
    }
}

#if os(macOS)
public struct ShellGitHistoryService: Sendable {
    private let runner: GitProcessRunner

    public init(runner: GitProcessRunner = GitProcessRunner()) {
        self.runner = runner
    }

    public func branchSummary(at repo: URL) async throws -> GitBranchSummary {
        let branch = try? require(["branch", "--show-current"], in: repo, label: "branch --show-current")
            .standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let upstream = try? require(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: repo, label: "upstream")
            .standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        var ahead = 0
        var behind = 0
        if let counts = try? require(["rev-list", "--left-right", "--count", "HEAD...@{u}"], in: repo, label: "ahead behind") {
            let parts = counts.standardOutput.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
            if parts.count >= 2 {
                ahead = Int(parts[0]) ?? 0
                behind = Int(parts[1]) ?? 0
            }
        }
        return GitBranchSummary(
            currentBranch: branch?.isEmpty == false ? branch : nil,
            upstream: upstream?.isEmpty == false ? upstream : nil,
            ahead: ahead,
            behind: behind
        )
    }

    public func commitGraph(at repo: URL, limit: Int = 120) async throws -> [GitCommitNode] {
        try logCommits(
            at: repo,
            args: ["log", "--date-order", "--decorate=short", "-n", String(limit)],
            label: "log"
        )
    }

    public func searchCommits(
        at repo: URL,
        query: String,
        mode: GitHistorySearchMode,
        limit: Int = 80
    ) async throws -> [GitCommitNode] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else { return [] }
        let count = max(1, min(limit, 200))
        let searchArg: String
        switch mode {
        case .message:
            searchArg = "--regexp-ignore-case"
        case .changes:
            searchArg = "-S\(cleanQuery)"
        }
        let args: [String]
        switch mode {
        case .message:
            args = ["log", "--date-order", "--decorate=short", "-n", String(count), searchArg, "--grep=\(cleanQuery)", "--all-match"]
        case .changes:
            args = ["log", "--date-order", "--decorate=short", "-n", String(count), searchArg]
        }
        return try logCommits(at: repo, args: args, label: "log search")
    }

    private func logCommits(at repo: URL, args: [String], label: String) throws -> [GitCommitNode] {
        let format = "%H%x1f%h%x1f%P%x1f%D%x1f%an%x1f%aI%x1f%s%x1f%b%x1e"
        let result = try require(
            args + ["--format=\(format)"],
            in: repo,
            label: label
        )
        let iso = ISO8601DateFormatter()
        return result.standardOutput
            .split(separator: "\u{1e}", omittingEmptySubsequences: true)
            .compactMap { record in
                let fields = record.split(separator: "\u{1f}", maxSplits: 7, omittingEmptySubsequences: false)
                guard fields.count == 8 else { return nil }
                let id = String(fields[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else { return nil }
                let parents = fields[2].split(separator: " ").map(String.init)
                let decorations = fields[3].split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                return GitCommitNode(
                    id: id,
                    shortID: String(fields[1]),
                    parentIDs: parents,
                    decorations: decorations,
                    author: String(fields[4]),
                    authorDate: iso.date(from: String(fields[5])) ?? Date(timeIntervalSince1970: 0),
                    subject: String(fields[6]),
                    body: String(fields[7]).trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
    }

    public func branches(at repo: URL) async throws -> [GitBranch] {
        let currentBranch = try? require(["branch", "--show-current"], in: repo, label: "branch --show-current")
            .standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let upstreamByBranch = try localUpstreams(at: repo)
        let format = "%(refname)%09%(refname:short)%09%(objectname)%09%(objectname:short)%09%(subject)%09%(committerdate:iso-strict)%09%(committerdate:relative)"
        let result = try require(
            ["for-each-ref", "--sort=-committerdate", "--format=\(format)", "refs/heads", "refs/remotes"],
            in: repo,
            label: "for-each-ref branches"
        )
        let iso = ISO8601DateFormatter()
        return result.standardOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { record in
                let fields = record.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false)
                guard fields.count == 7 else { return nil }
                let name = String(fields[0])
                let shortName = String(fields[1])
                let kind: GitBranch.Kind
                if name.hasPrefix("refs/heads/") {
                    kind = .local
                } else if name.hasPrefix("refs/remotes/") {
                    guard shortName != "origin/HEAD" && !shortName.hasSuffix("/HEAD") else { return nil }
                    kind = .remote
                } else {
                    return nil
                }
                return GitBranch(
                    name: name,
                    shortName: shortName,
                    kind: kind,
                    commitID: String(fields[2]),
                    shortCommitID: String(fields[3]),
                    subject: String(fields[4]),
                    updatedAt: iso.date(from: String(fields[5])),
                    updatedDescription: String(fields[6]),
                    isCurrent: kind == .local && shortName == currentBranch,
                    upstream: kind == .local ? upstreamByBranch[shortName] : nil
                )
            }
    }

    public func tags(at repo: URL) async throws -> [GitTag] {
        let format = "%(refname:short)%09%(objectname)%09%(objectname:short)%09%(subject)"
        let result = try require(
            ["for-each-ref", "--sort=-creatordate", "--format=\(format)", "refs/tags"],
            in: repo,
            label: "for-each-ref tags"
        )
        return result.standardOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { record in
                let fields = record.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                guard fields.count == 4 else { return nil }
                return GitTag(
                    name: String(fields[0]),
                    commitID: String(fields[1]),
                    shortCommitID: String(fields[2]),
                    subject: String(fields[3])
                )
            }
    }

    public func remotes(at repo: URL) async throws -> [GitRemote] {
        let result = try require(["remote", "-v"], in: repo, label: "remote -v")
        var remotesByName: [String: (fetch: String?, push: String?)] = [:]
        for line in result.standardOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 3 else { continue }
            let name = fields[0]
            let url = fields[1]
            let direction = fields[2]
            var remote = remotesByName[name] ?? (fetch: nil, push: nil)
            if direction == "(fetch)" {
                remote.fetch = url
            } else if direction == "(push)" {
                remote.push = url
            }
            remotesByName[name] = remote
        }
        return remotesByName.keys.sorted().map { name in
            let remote = remotesByName[name] ?? (fetch: nil, push: nil)
            return GitRemote(name: name, fetchURL: remote.fetch, pushURL: remote.push)
        }
    }

    public func addRemote(at repo: URL, name: String, url: String) async throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw GitRewriteError.invalidBranchName(name) }
        guard !cleanURL.isEmpty else { throw GitEngineError.commandFailed(command: "remote add", exitCode: 1, stderr: "Remote URL is required.") }
        try require(["remote", "add", cleanName, cleanURL], in: repo, label: "remote add")
    }

    public func removeRemote(at repo: URL, name: String) async throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw GitRewriteError.invalidBranchName(name) }
        try require(["remote", "remove", cleanName], in: repo, label: "remote remove")
    }

    public func createBranch(at repo: URL, name: String, startPoint: String = "HEAD", checkout: Bool) async throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw GitRewriteError.invalidBranchName(name) }
        try requireCleanTree(at: repo)
        try validateBranchName(cleanName, at: repo)
        try ensureCommitExists(startPoint, at: repo)
        if checkout {
            try require(["switch", "-c", cleanName, startPoint], in: repo, label: "switch -c")
        } else {
            try require(["branch", cleanName, startPoint], in: repo, label: "branch create")
        }
    }

    public func checkoutBranch(at repo: URL, name: String) async throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw GitRewriteError.invalidBranchName(name) }
        try requireCleanTree(at: repo)
        try require(["switch", cleanName], in: repo, label: "switch branch")
    }

    public func checkoutRemoteBranch(at repo: URL, remoteName: String) async throws {
        let cleanName = remoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw GitRewriteError.invalidBranchName(remoteName) }
        try requireCleanTree(at: repo)
        try require(["switch", "--track", cleanName], in: repo, label: "switch --track remote branch")
    }

    public func renameBranch(at repo: URL, oldName: String, newName: String) async throws {
        let cleanOldName = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNewName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanOldName.isEmpty else { throw GitRewriteError.invalidBranchName(oldName) }
        guard !cleanNewName.isEmpty else { throw GitRewriteError.invalidBranchName(newName) }
        try requireCleanTree(at: repo)
        try validateBranchName(cleanNewName, at: repo)
        try require(["branch", "-m", cleanOldName, cleanNewName], in: repo, label: "branch rename")
    }

    public func deleteBranch(at repo: URL, name: String) async throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw GitRewriteError.invalidBranchName(name) }
        let current = try? currentBranch(at: repo)
        guard current != cleanName else { throw GitRewriteError.invalidBranchName(name) }
        try requireCleanTree(at: repo)
        try require(["branch", "-d", cleanName], in: repo, label: "branch delete")
    }

    public func createTag(at repo: URL, name: String, target: String = "HEAD") async throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw GitRewriteError.invalidTagName(name) }
        try requireCleanTree(at: repo)
        try validateTagName(cleanName, at: repo)
        try ensureCommitExists(target, at: repo)
        try require(["tag", cleanName, target], in: repo, label: "tag create")
    }

    public func deleteTag(at repo: URL, name: String) async throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw GitRewriteError.invalidTagName(name) }
        try requireCleanTree(at: repo)
        try require(["tag", "-d", cleanName], in: repo, label: "tag delete")
    }

    public func mergeBranch(at repo: URL, name: String) async throws -> GitBranchOperationResult {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw GitRewriteError.invalidBranchName(name) }
        try requireCleanTree(at: repo)
        let result = try runner.run(["merge", "--no-edit", cleanName], in: repo)
        if result.succeeded {
            return GitBranchOperationResult(completed: true)
        }
        let conflictList = try await conflicts(at: repo)
        guard !conflictList.isEmpty else {
            throw GitEngineError.commandFailed(command: "merge", exitCode: result.exitCode, stderr: result.standardError)
        }
        return GitBranchOperationResult(completed: false, conflicts: conflictList)
    }

    public func rebaseCurrentBranch(onto name: String, at repo: URL) async throws -> GitBranchOperationResult {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw GitRewriteError.invalidBranchName(name) }
        try requireCleanTree(at: repo)
        let result = try runner.run(["rebase", cleanName], in: repo)
        if result.succeeded {
            return GitBranchOperationResult(completed: true)
        }
        let conflictList = try await conflicts(at: repo)
        guard !conflictList.isEmpty else {
            throw GitEngineError.commandFailed(command: "rebase", exitCode: result.exitCode, stderr: result.standardError)
        }
        return GitBranchOperationResult(completed: false, conflicts: conflictList)
    }

    public func branchFlow(at repo: URL, targetBranch: String) async throws -> GitBranchFlow {
        let current = try currentBranch(at: repo)
        let cleanTarget = targetBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTarget.isEmpty else { throw GitRewriteError.invalidBranchName(targetBranch) }
        let base = try require(["merge-base", current, cleanTarget], in: repo, label: "merge-base").standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseItem = try previewItem(for: base, currentIndex: nil, plannedIndex: 0, at: repo)
        let currentOnly = try branchFlowItems(for: "\(cleanTarget)..\(current)", at: repo)
        let targetOnly = try branchFlowItems(for: "\(current)..\(cleanTarget)", at: repo)
        let changedFiles = try changedFilesBetween(at: repo, from: current, to: cleanTarget)
        return GitBranchFlow(
            currentBranch: current,
            targetBranch: cleanTarget,
            mergeBaseID: baseItem.id,
            mergeBaseShortID: baseItem.shortID,
            mergeBaseSubject: baseItem.subject,
            currentOnlyCommits: currentOnly,
            targetOnlyCommits: targetOnly,
            changedFiles: changedFiles
        )
    }

    public func changedFiles(at repo: URL, commit: String) async throws -> [GitChangedFile] {
        let result = try require(["diff-tree", "--no-commit-id", "--name-status", "-r", "-M", commit], in: repo, label: "diff-tree")
        return parseNameStatus(result.standardOutput)
    }

    public func changedFilesBetween(at repo: URL, from base: String, to target: String) throws -> [GitChangedFile] {
        let cleanBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBase.isEmpty, !cleanTarget.isEmpty else { throw GitRewriteError.emptySelection }
        try ensureCommitExists(cleanBase, at: repo)
        try ensureCommitExists(cleanTarget, at: repo)
        let result = try require(["diff", "--name-status", "-M", cleanBase, cleanTarget], in: repo, label: "diff --name-status")
        return parseNameStatus(result.standardOutput)
    }

    public func diff(at repo: URL, commit: String) async throws -> [GitFileDiff] {
        let result = try require(["show", "--format=", "--find-renames", "--patch", commit], in: repo, label: "show")
        return parsePatch(result.standardOutput)
    }

    public func blame(at repo: URL, path: String, revision: String = "HEAD") async throws -> [GitBlameLine] {
        let cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPath.isEmpty else { return [] }
        let result = try require(
            ["blame", "--line-porcelain", revision, "--", cleanPath],
            in: repo,
            label: "blame"
        )
        return Self.parseBlamePorcelain(result.standardOutput)
    }

    public func conflicts(at repo: URL) async throws -> [GitFileConflict] {
        let result = try require(["diff", "--name-only", "--diff-filter=U"], in: repo, label: "unmerged paths")
        let paths = result.standardOutput.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return try paths.map { path in
            let text = try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
            return GitFileConflict(path: path, sections: Self.parseConflictSections(text))
        }
    }

    public func worktreeFiles(at repo: URL) async throws -> [GitWorktreeFile] {
        let result = try require(["status", "--porcelain=v1", "-z"], in: repo, label: "status --porcelain")
        let records = result.standardOutput.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var files: [GitWorktreeFile] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            guard record.count >= 3 else {
                index += 1
                continue
            }
            let indexStatus = String(record[record.startIndex])
            let worktreeIndex = record.index(after: record.startIndex)
            let workingTreeStatus = String(record[worktreeIndex])
            let pathStart = record.index(record.startIndex, offsetBy: 3)
            let path = String(record[pathStart...])
            if indexStatus == "R" || indexStatus == "C" {
                let original = index + 1 < records.count ? records[index + 1] : nil
                files.append(GitWorktreeFile(path: path, indexStatus: indexStatus, workingTreeStatus: workingTreeStatus, originalPath: original))
                index += 2
            } else {
                files.append(GitWorktreeFile(path: path, indexStatus: indexStatus, workingTreeStatus: workingTreeStatus))
                index += 1
            }
        }
        return files
    }

    public func linkedWorktrees(at repo: URL) async throws -> [GitLinkedWorktree] {
        let result = try require(["worktree", "list", "--porcelain"], in: repo, label: "worktree list")
        let currentPath = repo.standardizedFileURL.path
        return parseLinkedWorktrees(result.standardOutput, currentPath: currentPath)
    }

    public func addLinkedWorktree(at repo: URL, path: String, branchName: String) async throws {
        let cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPath.isEmpty else { throw GitRewriteError.emptySelection }
        guard !cleanBranch.isEmpty else { throw GitRewriteError.invalidBranchName(branchName) }
        try validateBranchName(cleanBranch, at: repo)
        try require(["worktree", "add", cleanPath, "-b", cleanBranch, "HEAD"], in: repo, label: "worktree add")
    }

    public func removeLinkedWorktree(at repo: URL, path: String) async throws {
        let cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPath.isEmpty else { throw GitRewriteError.emptySelection }
        let currentPath = repo.standardizedFileURL.path
        guard URL(fileURLWithPath: cleanPath).standardizedFileURL.path != currentPath else {
            throw GitEngineError.commandFailed(command: "worktree remove", exitCode: 1, stderr: "The open repository worktree cannot be removed.")
        }
        try require(["worktree", "remove", cleanPath], in: repo, label: "worktree remove")
    }

    public func submodules(at repo: URL) async throws -> [GitSubmodule] {
        let result = try require(["submodule", "status", "--recursive"], in: repo, label: "submodule status")
        return parseSubmodules(result.standardOutput)
    }

    public func updateSubmodules(at repo: URL, paths: [String] = []) async throws {
        let cleanPaths = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        try require(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "--recursive"] + cleanPaths,
            in: repo,
            label: "submodule update"
        )
    }

    public func stashes(at repo: URL) async throws -> [GitStashEntry] {
        let result = try require(["stash", "list", "--format=%gd%x09%gs"], in: repo, label: "stash list")
        return result.standardOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2 else { return nil }
                let id = parts[0]
                let index = Self.stashIndex(from: id) ?? 0
                let parsed = Self.parseStashSubject(parts[1])
                return GitStashEntry(id: id, index: index, branch: parsed.branch, message: parsed.message)
            }
    }

    public func reflogEntries(at repo: URL, limit: Int = 40) async throws -> [GitReflogEntry] {
        let count = max(1, min(limit, 200))
        let result = try require(
            ["reflog", "show", "--date=iso-strict", "--format=%H%x1f%h%x1f%gd%x1f%gs%x1f%an%x1f%ai", "-n", "\(count)"],
            in: repo,
            label: "reflog show"
        )
        return result.standardOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 6 else { return nil }
                return GitReflogEntry(
                    commitID: parts[0],
                    shortCommitID: parts[1],
                    selector: parts[2],
                    subject: parts[3],
                    author: parts[4],
                    date: Self.parseGitDate(parts[5]),
                    dateDescription: parts[5]
                )
            }
    }

    public func saveStash(at repo: URL, message: String, paths: [String] = []) async throws {
        let cleanMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPaths = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if cleanPaths.isEmpty {
            let files = try await worktreeFiles(at: repo)
            guard !files.isEmpty else { throw GitRewriteError.emptySelection }
        }
        let finalMessage = cleanMessage.isEmpty ? "GitBud stash" : cleanMessage
        let pathArgs = cleanPaths.isEmpty ? [] : ["--"] + cleanPaths
        try require(["stash", "push", "--include-untracked", "-m", finalMessage] + pathArgs, in: repo, label: "stash push")
    }

    public func applyStash(at repo: URL, id: String) async throws {
        let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty else { throw GitRewriteError.emptySelection }
        try requireCleanTree(at: repo)
        try require(["stash", "apply", cleanID], in: repo, label: "stash apply")
    }

    public func popStash(at repo: URL, id: String) async throws -> GitBranchOperationResult {
        let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty else { throw GitRewriteError.emptySelection }
        try requireCleanTree(at: repo)
        let result = try runner.run(["stash", "pop", cleanID], in: repo, timeoutSeconds: 120)
        if result.succeeded {
            return GitBranchOperationResult(completed: true, conflicts: [])
        }
        let conflicts = try await conflicts(at: repo)
        if !conflicts.isEmpty {
            return GitBranchOperationResult(completed: false, conflicts: conflicts)
        }
        throw GitEngineError.commandFailed(command: "stash pop", exitCode: result.exitCode, stderr: result.standardError)
    }

    public func finishStashPop(at repo: URL, id: String) async throws {
        let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty else { throw GitRewriteError.emptySelection }
        let conflictList = try await conflicts(at: repo)
        guard conflictList.isEmpty else { throw GitRewriteError.dirtyWorkingTree }
        try require(["stash", "drop", cleanID], in: repo, label: "stash drop after pop")
    }

    public func abortStashPop(at repo: URL) async throws {
        let conflictList = try await conflicts(at: repo)
        guard !conflictList.isEmpty else { throw GitRewriteError.emptySelection }
        try require(["reset", "--hard"], in: repo, label: "reset --hard abort stash pop")
    }

    public func createBranchFromStash(at repo: URL, id: String, branchName: String) async throws {
        let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBranchName = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty, !cleanBranchName.isEmpty else { throw GitRewriteError.emptySelection }
        try requireCleanTree(at: repo)
        try validateBranchName(cleanBranchName, at: repo)
        try require(["stash", "branch", cleanBranchName, cleanID], in: repo, label: "stash branch")
    }

    public func dropStash(at repo: URL, id: String) async throws {
        let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty else { throw GitRewriteError.emptySelection }
        try require(["stash", "drop", cleanID], in: repo, label: "stash drop")
    }

    public func stagePaths(at repo: URL, paths: [String]) async throws {
        guard !paths.isEmpty else { throw GitRewriteError.emptySelection }
        try require(["add", "--"] + paths, in: repo, label: "add paths")
    }

    public func unstagePaths(at repo: URL, paths: [String]) async throws {
        guard !paths.isEmpty else { throw GitRewriteError.emptySelection }
        try require(["restore", "--staged", "--"] + paths, in: repo, label: "restore --staged")
    }

    public func amendHeadWithPaths(at repo: URL, paths: [String]) async throws {
        let cleanPaths = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanPaths.isEmpty else { throw GitRewriteError.emptySelection }
        _ = try require(["rev-parse", "--verify", "HEAD"], in: repo, label: "rev-parse HEAD")

        let untracked = try untrackedPaths(at: repo, paths: cleanPaths)
        if !untracked.isEmpty {
            try require(["add", "-N", "--"] + untracked, in: repo, label: "add intent-to-add")
        }

        do {
            try require(["commit", "--amend", "--no-edit", "--only", "--"] + cleanPaths, in: repo, label: "commit --amend --only")
        } catch GitEngineError.commandFailed(_, _, let stderr) where stderr.contains("no changes") || stderr.contains("nothing to commit") {
            throw GitEngineError.nothingToCommit
        }
    }

    public func discardPaths(at repo: URL, paths: [String]) async throws {
        guard !paths.isEmpty else { throw GitRewriteError.emptySelection }
        var tracked: [String] = []
        var untracked: [String] = []
        for path in paths {
            let result = try runner.run(["ls-files", "--error-unmatch", "--", path], in: repo)
            if result.succeeded {
                tracked.append(path)
            } else {
                untracked.append(path)
            }
        }
        if !tracked.isEmpty {
            try require(["restore", "--worktree", "--"] + tracked, in: repo, label: "restore --worktree")
        }
        if !untracked.isEmpty {
            try require(["clean", "-f", "--"] + untracked, in: repo, label: "clean untracked paths")
        }
    }

    public func restorePaths(at repo: URL, paths: [String], from commit: String) async throws {
        let cleanPaths = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let cleanCommit = commit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPaths.isEmpty, !cleanCommit.isEmpty else { throw GitRewriteError.emptySelection }
        _ = try require(["rev-parse", "--verify", cleanCommit], in: repo, label: "rev-parse restore source")
        try require(["restore", "--source", cleanCommit, "--worktree", "--"] + cleanPaths, in: repo, label: "restore paths from commit")
    }

    public func createSafetyBranch(at repo: URL, prefix: String = "gitbud/safety") async throws -> String {
        let current = try require(["rev-parse", "--short", "HEAD"], in: repo, label: "rev-parse").standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = Int(Date().timeIntervalSince1970)
        let name = "\(prefix)-\(stamp)-\(current)"
        try require(["branch", name], in: repo, label: "branch")
        return name
    }

    public func forceWithLeaseReadiness(at repo: URL) async throws -> Bool {
        let status = try require(["status", "--porcelain"], in: repo, label: "status")
        guard status.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return (try? require(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: repo, label: "upstream")) != nil
    }

    public func pushCurrentBranch(at repo: URL) async throws {
        let branch = try currentBranch(at: repo)
        if (try? upstreamBranch(at: repo)) != nil {
            try require(["push"], in: repo, label: "push")
        } else {
            try require(["push", "-u", "origin", branch], in: repo, label: "push -u")
        }
    }

    public func pushForceWithLease(at repo: URL) async throws {
        try requireCleanTree(at: repo)
        let branch = try currentBranch(at: repo)
        guard (try? upstreamBranch(at: repo)) != nil else { throw GitRewriteError.noUpstream }
        try require(["push", "--force-with-lease", "origin", branch], in: repo, label: "push --force-with-lease")
    }

    public func rewritePreview(at repo: URL, oldestToNewest commitIDs: [String]) async throws -> GitRewritePreview {
        guard !commitIDs.isEmpty else { throw GitRewriteError.emptySelection }
        let base = try baseParent(forCommitSet: commitIDs, at: repo)
        let canonicalPlan = try commitIDs.map {
            try require(["rev-parse", $0], in: repo, label: "rev-parse").standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let selected = Set(canonicalPlan)
        let currentIDs = try require(["rev-list", "--reverse", "\(base)..HEAD"], in: repo, label: "rev-list rewrite range")
            .standardOutput
            .split(separator: "\n")
            .map(String.init)
            .filter { selected.contains($0) }
        let currentIndexByID = Dictionary(uniqueKeysWithValues: currentIDs.enumerated().map { ($0.element, $0.offset) })
        let plannedIndexByID = Dictionary(uniqueKeysWithValues: canonicalPlan.enumerated().map { ($0.element, $0.offset) })
        let currentItems = try currentIDs.map {
            try previewItem(for: $0, currentIndex: currentIndexByID[$0], plannedIndex: plannedIndexByID[$0] ?? 0, at: repo)
        }
        let plannedItems = try canonicalPlan.enumerated().map { offset, commit in
            try previewItem(for: commit, currentIndex: currentIndexByID[commit], plannedIndex: offset, at: repo)
        }
        return GitRewritePreview(baseCommitID: base, currentOldestToNewest: currentItems, plannedOldestToNewest: plannedItems)
    }

    public func squashRecentCommits(at repo: URL, count: Int, message: String) async throws {
        guard count > 1 else { throw GitRewriteError.notEnoughCommits }
        try requireCleanTree(at: repo)
        try ensureCommitExists("HEAD~\(count - 1)", at: repo)
        try require(["reset", "--soft", "HEAD~\(count)"], in: repo, label: "reset --soft")
        try require(["commit", "-m", message], in: repo, label: "commit")
    }

    public func editHeadCommitMessage(at repo: URL, message: String) async throws {
        try requireCleanTree(at: repo)
        try require(["commit", "--amend", "-m", message], in: repo, label: "commit --amend")
    }

    public func deleteFileAndCommit(at repo: URL, path: String, message: String) async throws {
        try requireCleanTree(at: repo)
        try require(["rm", "--", path], in: repo, label: "rm")
        try require(["commit", "-m", message], in: repo, label: "commit deletion")
    }

    @discardableResult
    public func purgePathsFromCurrentBranchHistory(at repo: URL, paths: [String]) async throws -> String {
        guard !paths.isEmpty else { throw GitRewriteError.emptySelection }
        try requireCleanTree(at: repo)
        let branch = try currentBranch(at: repo)
        let originalHead = try require(["rev-parse", "HEAD"], in: repo, label: "rev-parse HEAD").standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let backup = try await createSafetyBranch(at: repo, prefix: "gitbud/purge-backup")
        let tempBranch = "gitbud-purge-\(UUID().uuidString)"
        let commits = try require(["rev-list", "--reverse", "HEAD"], in: repo, label: "rev-list").standardOutput
            .split(separator: "\n")
            .map(String.init)
        guard !commits.isEmpty else { throw GitRewriteError.notEnoughCommits }

        do {
            try require(["checkout", "--orphan", tempBranch], in: repo, label: "checkout --orphan")
            _ = try? runner.run(["rm", "-rf", "--ignore-unmatch", "."], in: repo)

            for commit in commits {
                try require(["read-tree", "--reset", "-u", commit], in: repo, label: "read-tree")
                try require(["rm", "-rf", "--ignore-unmatch", "--"] + paths, in: repo, label: "rm purge paths")
                let status = try require(["status", "--porcelain"], in: repo, label: "status")
                guard !status.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let message = try require(["log", "-1", "--format=%B", commit], in: repo, label: "log message").standardOutput
                try commitAllAllowingInitialEmptyTree(at: repo, message: message)
            }

            try require(["branch", "-f", branch, "HEAD"], in: repo, label: "branch -f")
            try require(["checkout", branch], in: repo, label: "checkout branch")
            try require(["branch", "-D", tempBranch], in: repo, label: "branch -D temp")
            return backup
        } catch {
            _ = try? runner.run(["checkout", branch], in: repo)
            _ = try? runner.run(["reset", "--hard", originalHead], in: repo)
            _ = try? runner.run(["branch", "-D", tempBranch], in: repo)
            throw error
        }
    }

    public func purgePreview(at repo: URL, paths: [String]) async throws -> GitPurgePreview {
        let cleanPaths = paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.sorted()
        guard !cleanPaths.isEmpty else { throw GitRewriteError.emptySelection }
        let commitIDs = try require(["log", "--format=%H", "--"] + cleanPaths, in: repo, label: "log purge preview").standardOutput
            .split(separator: "\n")
            .map(String.init)
        let commits = try commitIDs.enumerated().map { index, commit in
            try previewItem(for: commit, currentIndex: index, plannedIndex: index, at: repo)
        }
        var branches = Set<String>()
        var tags = Set<String>()
        for commit in commitIDs {
            let branchOutput = (try? require(["branch", "--contains", commit, "--format=%(refname:short)"], in: repo, label: "branch --contains").standardOutput) ?? ""
            branches.formUnion(branchOutput.split(separator: "\n").map(String.init).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            let tagOutput = (try? require(["tag", "--contains", commit], in: repo, label: "tag --contains").standardOutput) ?? ""
            tags.formUnion(tagOutput.split(separator: "\n").map(String.init).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }
        return GitPurgePreview(
            paths: cleanPaths,
            affectedCommits: commits,
            affectedBranches: branches.sorted(),
            affectedTags: tags.sorted(),
            repositorySizeBytes: repositorySizeBytes(at: repo)
        )
    }

    public func dropCommit(at repo: URL, commit: String) async throws {
        try requireCleanTree(at: repo)
        try ensureCommitExists("\(commit)^", at: repo)
        try require(["rebase", "--onto", "\(commit)^", commit, "HEAD"], in: repo, label: "rebase --onto")
    }

    @discardableResult
    public func resetCurrentBranchToCommit(at repo: URL, commit: String) async throws -> String {
        let cleanCommit = commit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCommit.isEmpty else { throw GitRewriteError.emptySelection }
        try requireCleanTree(at: repo)
        try ensureCommitExists(cleanCommit, at: repo)
        let backup = try await createSafetyBranch(at: repo, prefix: "gitbud/reset-backup")
        try require(["reset", "--mixed", cleanCommit], in: repo, label: "reset --mixed selected commit")
        return backup
    }

    @discardableResult
    public func recoverCurrentBranch(to entry: GitReflogEntry, at repo: URL) async throws -> String {
        try await recoverCurrentBranchToCommit(at: repo, commit: entry.commitID)
    }

    @discardableResult
    public func recoverCurrentBranchToCommit(at repo: URL, commit: String) async throws -> String {
        let cleanCommit = commit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCommit.isEmpty else { throw GitRewriteError.emptySelection }
        try requireCleanTree(at: repo)
        try ensureCommitExists(cleanCommit, at: repo)
        let backup = try await createSafetyBranch(at: repo, prefix: "gitbud/recovery-backup")
        try require(["reset", "--hard", cleanCommit], in: repo, label: "reset --hard reflog commit")
        return backup
    }

    public func revertCommit(at repo: URL, commit: String) async throws -> GitBranchOperationResult {
        try requireCleanTree(at: repo)
        try ensureCommitExists(commit, at: repo)
        let result = try runner.run(
            ["-c", "core.editor=true", "revert", "--no-edit", commit],
            in: repo,
            timeoutSeconds: 120
        )
        if result.succeeded {
            return GitBranchOperationResult(completed: true, conflicts: [])
        }
        let conflicts = try await conflicts(at: repo)
        if !conflicts.isEmpty {
            return GitBranchOperationResult(completed: false, conflicts: conflicts)
        }
        throw GitEngineError.commandFailed(command: "revert", exitCode: result.exitCode, stderr: result.standardError)
    }

    public func cherryPickCommit(at repo: URL, commit: String) async throws -> GitBranchOperationResult {
        try requireCleanTree(at: repo)
        try ensureCommitExists(commit, at: repo)
        let result = try runner.run(
            ["-c", "core.editor=true", "cherry-pick", commit],
            in: repo,
            timeoutSeconds: 120
        )
        if result.succeeded {
            return GitBranchOperationResult(completed: true, conflicts: [])
        }
        let conflicts = try await conflicts(at: repo)
        if !conflicts.isEmpty {
            return GitBranchOperationResult(completed: false, conflicts: conflicts)
        }
        throw GitEngineError.commandFailed(command: "cherry-pick", exitCode: result.exitCode, stderr: result.standardError)
    }

    public func reorderCommits(at repo: URL, oldestToNewest commitIDs: [String]) async throws {
        guard !commitIDs.isEmpty else { throw GitRewriteError.emptySelection }
        try requireCleanTree(at: repo)
        let base = try baseParent(forCommitSet: commitIDs, at: repo)
        try ensureCommitExists(base, at: repo)
        let originalHead = try require(["rev-parse", "HEAD"], in: repo, label: "rev-parse HEAD").standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(["reset", "--hard", base], in: repo, label: "reset --hard")
        do {
            for commit in commitIDs {
                try require(["cherry-pick", commit], in: repo, label: "cherry-pick")
            }
        } catch {
            _ = try? runner.run(["cherry-pick", "--abort"], in: repo)
            _ = try? runner.run(["reset", "--hard", originalHead], in: repo)
            throw error
        }
    }

    public func splitHeadCommitByFiles(
        at repo: URL,
        paths: [String],
        newCommitMessage: String,
        remainingCommitMessage: String
    ) async throws {
        guard !paths.isEmpty else { throw GitRewriteError.emptySelection }
        try requireCleanTree(at: repo)
        try ensureCommitExists("HEAD^", at: repo)
        try require(["reset", "--mixed", "HEAD^"], in: repo, label: "reset --mixed")
        try require(["add", "--"] + paths, in: repo, label: "add selected")
        try require(["commit", "-m", newCommitMessage], in: repo, label: "commit selected")
        try require(["add", "-A"], in: repo, label: "add remaining")
        let staged = try runner.run(["diff", "--cached", "--quiet"], in: repo)
        if staged.succeeded {
            throw GitRewriteError.nothingLeftAfterSplit
        }
        try require(["commit", "-m", remainingCommitMessage], in: repo, label: "commit remaining")
    }

    public func splitCommitByFiles(
        at repo: URL,
        commit: String,
        paths: [String],
        newCommitMessage: String,
        remainingCommitMessage: String
    ) async throws {
        guard !paths.isEmpty else { throw GitRewriteError.emptySelection }
        try requireCleanTree(at: repo)
        let selectedCommit = try require(["rev-parse", commit], in: repo, label: "rev-parse selected commit").standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = try require(["rev-parse", "\(selectedCommit)^"], in: repo, label: "rev-parse selected parent").standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let originalHead = try require(["rev-parse", "HEAD"], in: repo, label: "rev-parse HEAD").standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isAncestor = try runner.run(["merge-base", "--is-ancestor", selectedCommit, "HEAD"], in: repo)
        guard isAncestor.succeeded else { throw GitRewriteError.unsupportedCommit(commit) }

        let changed = try await changedFiles(at: repo, commit: selectedCommit).map(\.path)
        let selectedPaths = Array(Set(paths).intersection(Set(changed))).sorted()
        guard !selectedPaths.isEmpty else { throw GitRewriteError.emptySelection }
        let remainingPaths = changed.filter { !selectedPaths.contains($0) }
        let laterCommits = try require(["rev-list", "--reverse", "\(selectedCommit)..HEAD"], in: repo, label: "rev-list later commits").standardOutput
            .split(separator: "\n")
            .map(String.init)

        do {
            try require(["reset", "--hard", parent], in: repo, label: "reset to selected parent")
            try applyCommitPatch(from: parent, to: selectedCommit, paths: selectedPaths, at: repo, label: "apply selected commit files")
            try require(["commit", "-m", newCommitMessage], in: repo, label: "commit selected files")

            if !remainingPaths.isEmpty {
                try applyCommitPatch(from: parent, to: selectedCommit, paths: remainingPaths, at: repo, label: "apply remaining commit files")
                try require(["commit", "-m", remainingCommitMessage], in: repo, label: "commit remaining files")
            }

            for later in laterCommits {
                try require(["cherry-pick", later], in: repo, label: "cherry-pick later commit")
            }
        } catch {
            _ = try? runner.run(["cherry-pick", "--abort"], in: repo)
            _ = try? runner.run(["reset", "--hard", originalHead], in: repo)
            throw error
        }
    }

    public func splitHeadCommitByHunks(
        at repo: URL,
        hunkIDs: Set<String>,
        newCommitMessage: String,
        remainingCommitMessage: String
    ) async throws {
        guard !hunkIDs.isEmpty else { throw GitRewriteError.emptySelection }
        try requireCleanTree(at: repo)
        try ensureCommitExists("HEAD^", at: repo)
        try require(["reset", "--mixed", "HEAD^"], in: repo, label: "reset --mixed")
        let patch = try require(["diff", "--patch"], in: repo, label: "diff").standardOutput
        let selectedPatch = selectedPatch(from: patch, hunkIDs: hunkIDs)
        guard !selectedPatch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitRewriteError.emptySelection
        }
        let patchURL = repo.appendingPathComponent(".git/gitbud-selected.patch")
        try Data(selectedPatch.utf8).write(to: patchURL)
        defer { try? FileManager.default.removeItem(at: patchURL) }
        try require(["apply", "--cached", patchURL.path], in: repo, label: "apply selected hunks")
        try require(["commit", "-m", newCommitMessage], in: repo, label: "commit selected hunks")
        try require(["add", "-A"], in: repo, label: "add remaining")
        let staged = try runner.run(["diff", "--cached", "--quiet"], in: repo)
        if staged.succeeded {
            throw GitRewriteError.nothingLeftAfterSplit
        }
        try require(["commit", "-m", remainingCommitMessage], in: repo, label: "commit remaining")
    }

    public func splitCommitByHunks(
        at repo: URL,
        commit: String,
        hunkIDs: Set<String>,
        newCommitMessage: String,
        remainingCommitMessage: String
    ) async throws {
        guard !hunkIDs.isEmpty else { throw GitRewriteError.emptySelection }
        try requireCleanTree(at: repo)
        let selectedCommit = try require(["rev-parse", commit], in: repo, label: "rev-parse selected commit").standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = try require(["rev-parse", "\(selectedCommit)^"], in: repo, label: "rev-parse selected parent").standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let originalHead = try require(["rev-parse", "HEAD"], in: repo, label: "rev-parse HEAD").standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isAncestor = try runner.run(["merge-base", "--is-ancestor", selectedCommit, "HEAD"], in: repo)
        guard isAncestor.succeeded else { throw GitRewriteError.unsupportedCommit(commit) }
        let laterCommits = try require(["rev-list", "--reverse", "\(selectedCommit)..HEAD"], in: repo, label: "rev-list later commits").standardOutput
            .split(separator: "\n")
            .map(String.init)
        let patch = try require(["diff", "--patch", parent, selectedCommit], in: repo, label: "diff selected commit patch").standardOutput
        let selectedPatch = filteredPatch(from: patch, hunkIDs: hunkIDs, includeSelected: true)
        let remainingPatch = filteredPatch(from: patch, hunkIDs: hunkIDs, includeSelected: false)
        guard !selectedPatch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitRewriteError.emptySelection
        }

        do {
            try require(["reset", "--hard", parent], in: repo, label: "reset to selected parent")
            try applyPatch(selectedPatch, at: repo, cached: false, label: "apply selected hunks")
            try require(["commit", "-m", newCommitMessage], in: repo, label: "commit selected hunks")

            if !remainingPatch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try applyPatch(remainingPatch, at: repo, cached: false, label: "apply remaining hunks")
                try require(["commit", "-m", remainingCommitMessage], in: repo, label: "commit remaining hunks")
            }

            for later in laterCommits {
                try require(["cherry-pick", later], in: repo, label: "cherry-pick later commit")
            }
        } catch {
            _ = try? runner.run(["cherry-pick", "--abort"], in: repo)
            _ = try? runner.run(["reset", "--hard", originalHead], in: repo)
            throw error
        }
    }

    public func resolveConflict(
        at repo: URL,
        path: String,
        taking resolution: GitRewriteResolution,
        mode: GitRewriteConflictMode
    ) async throws {
        let checkoutSide: String
        switch (mode, resolution) {
        case (.merge, .yourChange):
            checkoutSide = "--ours"
        case (.merge, .remoteChange):
            checkoutSide = "--theirs"
        case (.revert, .yourChange):
            checkoutSide = "--ours"
        case (.revert, .remoteChange):
            checkoutSide = "--theirs"
        case (.cherryPick, .yourChange):
            checkoutSide = "--ours"
        case (.cherryPick, .remoteChange):
            checkoutSide = "--theirs"
        case (.stashPop, .yourChange):
            checkoutSide = "--ours"
        case (.stashPop, .remoteChange):
            checkoutSide = "--theirs"
        case (.rebase, .yourChange):
            // During rebase, "theirs" is the commit being replayed.
            checkoutSide = "--theirs"
        case (.rebase, .remoteChange):
            // During rebase, "ours" is the upstream/base side.
            checkoutSide = "--ours"
        }
        try require(["checkout", checkoutSide, "--", path], in: repo, label: "checkout conflict side")
        try require(["add", "--", path], in: repo, label: "add resolved conflict")
    }

    public func resolveConflict(at repo: URL, path: String, content: String) async throws {
        let fileURL = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: fileURL)
        try require(["add", "--", path], in: repo, label: "add resolved conflict")
    }

    public func continueRebase(at repo: URL) async throws {
        try require(["-c", "core.editor=true", "-c", "sequence.editor=true", "rebase", "--continue"], in: repo, label: "rebase --continue")
    }

    public func abortRebase(at repo: URL) async throws {
        try require(["rebase", "--abort"], in: repo, label: "rebase --abort")
    }

    public func continueMerge(at repo: URL) async throws {
        try require(["-c", "core.editor=true", "merge", "--continue"], in: repo, label: "merge --continue")
    }

    public func abortMerge(at repo: URL) async throws {
        try require(["merge", "--abort"], in: repo, label: "merge --abort")
    }

    public func continueRevert(at repo: URL) async throws {
        let result = try runner.run(["-c", "core.editor=true", "revert", "--continue"], in: repo)
        if result.succeeded { return }
        if isEmptySequencerStep(result) {
            try require(["revert", "--skip"], in: repo, label: "revert --skip")
            return
        }
        throw GitEngineError.commandFailed(command: "revert --continue", exitCode: result.exitCode, stderr: result.standardError)
    }

    public func abortRevert(at repo: URL) async throws {
        try require(["revert", "--abort"], in: repo, label: "revert --abort")
    }

    public func continueCherryPick(at repo: URL) async throws {
        let result = try runner.run(["-c", "core.editor=true", "cherry-pick", "--continue"], in: repo)
        if result.succeeded { return }
        if isEmptySequencerStep(result) {
            try require(["cherry-pick", "--skip"], in: repo, label: "cherry-pick --skip")
            return
        }
        throw GitEngineError.commandFailed(command: "cherry-pick --continue", exitCode: result.exitCode, stderr: result.standardError)
    }

    public func abortCherryPick(at repo: URL) async throws {
        try require(["cherry-pick", "--abort"], in: repo, label: "cherry-pick --abort")
    }

    public static func parseConflictSections(_ text: String) -> [GitConflictSection] {
        enum Mode { case normal, yours, theirs }
        var mode = Mode.normal
        var yourLines: [String] = []
        var remoteLines: [String] = []
        var sections: [GitConflictSection] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("<<<<<<<") {
                mode = .yours
                yourLines = []
                remoteLines = []
            } else if line.hasPrefix("=======") {
                mode = .theirs
            } else if line.hasPrefix(">>>>>>>") {
                sections.append(GitConflictSection(side: .yourChange, lines: yourLines))
                sections.append(GitConflictSection(side: .remoteChange, lines: remoteLines))
                mode = .normal
            } else {
                switch mode {
                case .normal: break
                case .yours: yourLines.append(line)
                case .theirs: remoteLines.append(line)
                }
            }
        }
        return sections
    }

    public static func parseBlamePorcelain(_ text: String) -> [GitBlameLine] {
        var lines: [GitBlameLine] = []
        var commitID = ""
        var lineNumber = 0
        var author = ""
        var summary = ""

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if rawLine.hasPrefix("\t") {
                let content = String(rawLine.dropFirst())
                guard !commitID.isEmpty, lineNumber > 0 else { continue }
                lines.append(
                    GitBlameLine(
                        lineNumber: lineNumber,
                        commitID: commitID,
                        shortCommitID: String(commitID.prefix(8)),
                        author: author,
                        summary: summary,
                        content: content
                    )
                )
                author = ""
                summary = ""
                continue
            }

            let fields = rawLine.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
            if fields.count >= 3, fields[0].count >= 7, fields[0].allSatisfy({ $0.isHexDigit }) {
                commitID = fields[0]
                lineNumber = Int(fields[2]) ?? 0
            } else if rawLine.hasPrefix("author ") {
                author = String(rawLine.dropFirst("author ".count))
            } else if rawLine.hasPrefix("summary ") {
                summary = String(rawLine.dropFirst("summary ".count))
            }
        }

        return lines
    }

    private func isEmptySequencerStep(_ result: GitCommandResult) -> Bool {
        let output = result.standardOutput + "\n" + result.standardError
        return output.contains("previous cherry-pick is now empty") ||
            output.contains("previous revert is now empty") ||
            output.contains("nothing to commit")
    }

    private func requireCleanTree(at repo: URL) throws {
        let status = try require(["status", "--porcelain"], in: repo, label: "status")
        guard status.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitRewriteError.dirtyWorkingTree
        }
    }

    private func currentBranch(at repo: URL) throws -> String {
        let branch = try require(["branch", "--show-current"], in: repo, label: "branch --show-current").standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { throw GitRewriteError.noCurrentBranch }
        return branch
    }

    private func upstreamBranch(at repo: URL) throws -> String {
        let upstream = try require(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: repo, label: "upstream").standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !upstream.isEmpty else { throw GitRewriteError.noUpstream }
        return upstream
    }

    private func untrackedPaths(at repo: URL, paths: [String]) throws -> [String] {
        let result = try require(["ls-files", "--others", "--exclude-standard", "--"] + paths, in: repo, label: "ls-files untracked")
        return result.standardOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func localUpstreams(at repo: URL) throws -> [String: String] {
        let format = "%(refname:short)%09%(upstream:short)"
        let result = try require(["for-each-ref", "--format=\(format)", "refs/heads"], in: repo, label: "for-each-ref upstreams")
        var upstreams: [String: String] = [:]
        for record in result.standardOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = record.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty else { continue }
            upstreams[fields[0]] = fields[1]
        }
        return upstreams
    }

    private func validateBranchName(_ name: String, at repo: URL) throws {
        let result = try runner.run(["check-ref-format", "--branch", name], in: repo)
        guard result.succeeded else {
            throw GitRewriteError.invalidBranchName(name)
        }
    }

    private func validateTagName(_ name: String, at repo: URL) throws {
        let result = try runner.run(["check-ref-format", "refs/tags/\(name)"], in: repo)
        guard result.succeeded else {
            throw GitRewriteError.invalidTagName(name)
        }
    }

    private static func stashIndex(from id: String) -> Int? {
        guard id.hasPrefix("stash@{"), id.hasSuffix("}") else { return nil }
        let start = id.index(id.startIndex, offsetBy: 7)
        let end = id.index(before: id.endIndex)
        return Int(id[start..<end])
    }

    private static func parseStashSubject(_ subject: String) -> (branch: String?, message: String) {
        let prefix = "On "
        guard subject.hasPrefix(prefix),
              let separator = subject.range(of: ": ") else {
            return (nil, subject)
        }
        let branch = String(subject[subject.index(subject.startIndex, offsetBy: prefix.count)..<separator.lowerBound])
        let message = String(subject[separator.upperBound...])
        return (branch.isEmpty ? nil : branch, message)
    }

    private static func parseGitDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private func commitAllAllowingInitialEmptyTree(at repo: URL, message: String) throws {
        try require(["add", "-A"], in: repo, label: "add all")
        let treeChanged = try runner.run(["diff", "--cached", "--quiet"], in: repo)
        guard !treeChanged.succeeded else { return }
        try require(["commit", "-m", message.trimmingCharacters(in: .whitespacesAndNewlines)], in: repo, label: "commit replayed purge")
    }

    private func applyCommitPatch(from parent: String, to commit: String, paths: [String], at repo: URL, label: String) throws {
        let patch = try require(["diff", "--binary", parent, commit, "--"] + paths, in: repo, label: "diff commit patch").standardOutput
        guard !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitRewriteError.emptySelection
        }
        try applyPatch(patch, at: repo, cached: false, label: label)
    }

    private func applyPatch(_ patch: String, at repo: URL, cached: Bool, label: String) throws {
        let patchURL = repo.appendingPathComponent(".git/gitbud-\(UUID().uuidString).patch")
        try Data(patch.utf8).write(to: patchURL)
        defer { try? FileManager.default.removeItem(at: patchURL) }
        let args = cached ? ["apply", "--cached", patchURL.path] : ["apply", "--index", patchURL.path]
        try require(args, in: repo, label: label)
    }

    private func ensureCommitExists(_ revision: String, at repo: URL) throws {
        _ = try require(["rev-parse", "--verify", revision], in: repo, label: "rev-parse")
    }

    private func baseParent(forCommitSet commitIDs: [String], at repo: URL) throws -> String {
        let canonical = try commitIDs.map { try require(["rev-parse", $0], in: repo, label: "rev-parse").standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) }
        let selected = Set(canonical)
        for commit in canonical {
            let line = try require(["rev-list", "--parents", "-n", "1", commit], in: repo, label: "rev-list parents").standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.split(separator: " ").map(String.init)
            let parents = parts.dropFirst()
            if let base = parents.first(where: { !selected.contains($0) }) {
                return base
            }
        }
        throw GitRewriteError.notEnoughCommits
    }

    private func previewItem(for commit: String, currentIndex: Int?, plannedIndex: Int, at repo: URL) throws -> GitRewritePreviewItem {
        let result = try require(["log", "-1", "--format=%H%x1f%h%x1f%s", commit], in: repo, label: "log preview item")
        let parts = result.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 3 else {
            return GitRewritePreviewItem(id: commit, shortID: String(commit.prefix(8)), subject: commit, currentIndex: currentIndex, plannedIndex: plannedIndex)
        }
        return GitRewritePreviewItem(id: parts[0], shortID: parts[1], subject: parts[2], currentIndex: currentIndex, plannedIndex: plannedIndex)
    }

    private func branchFlowItems(for revisionRange: String, at repo: URL) throws -> [GitRewritePreviewItem] {
        let commits = try require(["rev-list", "--reverse", revisionRange], in: repo, label: "rev-list branch flow").standardOutput
            .split(separator: "\n")
            .map(String.init)
        return try commits.enumerated().map { index, commit in
            try previewItem(for: commit, currentIndex: nil, plannedIndex: index, at: repo)
        }
    }

    private func repositorySizeBytes(at repo: URL) -> Int64? {
        let gitURL = repo.appendingPathComponent(".git", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: gitURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var size: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            size += Int64(values.fileSize ?? 0)
        }
        return size
    }

    private func parsePatch(_ patch: String) -> [GitFileDiff] {
        var files: [GitFileDiff] = []
        var oldPath: String?
        var path: String?
        var hunks: [GitHunk] = []
        var currentHeader: String?
        var currentLines: [String] = []

        func flushHunk() {
            guard let header = currentHeader else { return }
            hunks.append(GitHunk(id: "\(path ?? oldPath ?? "file"):\(hunks.count)", header: header, lines: currentLines))
            currentHeader = nil
            currentLines = []
        }

        func flushFile() {
            flushHunk()
            guard let finalPath = path else { return }
            files.append(GitFileDiff(path: finalPath, oldPath: oldPath, hunks: hunks))
            oldPath = nil
            path = nil
            hunks = []
        }

        for line in patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                flushFile()
            } else if line.hasPrefix("--- a/") {
                oldPath = String(line.dropFirst(6))
            } else if line == "--- /dev/null" {
                oldPath = nil
            } else if line.hasPrefix("+++ b/") {
                path = String(line.dropFirst(6))
            } else if line.hasPrefix("+++ /dev/null") {
                path = oldPath
            } else if line.hasPrefix("@@") {
                flushHunk()
                currentHeader = line
            } else if currentHeader != nil {
                currentLines.append(line)
            }
        }
        flushFile()
        return files
    }

    private func parseNameStatus(_ text: String) -> [GitChangedFile] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { return nil }
            if parts[0].hasPrefix("R"), parts.count >= 3 {
                return GitChangedFile(status: parts[0], path: parts[2], oldPath: parts[1])
            }
            return GitChangedFile(status: parts[0], path: parts[1])
        }
    }

    private func parseLinkedWorktrees(_ text: String, currentPath: String) -> [GitLinkedWorktree] {
        var worktrees: [GitLinkedWorktree] = []
        var path: String?
        var head: String?
        var branch: String?

        func flush() {
            guard let worktreePath = path else { return }
            let normalized = URL(fileURLWithPath: worktreePath).standardizedFileURL.path
            worktrees.append(
                GitLinkedWorktree(
                    path: normalized,
                    head: head,
                    branch: branch,
                    isCurrent: normalized == currentPath
                )
            )
            path = nil
            head = nil
            branch = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if rawLine.isEmpty {
                flush()
            } else if rawLine.hasPrefix("worktree ") {
                flush()
                path = String(rawLine.dropFirst("worktree ".count))
            } else if rawLine.hasPrefix("HEAD ") {
                head = String(rawLine.dropFirst("HEAD ".count))
            } else if rawLine.hasPrefix("branch ") {
                branch = String(rawLine.dropFirst("branch ".count))
                    .replacingOccurrences(of: "refs/heads/", with: "")
            }
        }
        flush()
        return worktrees
    }

    private func parseSubmodules(_ text: String) -> [GitSubmodule] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { rawLine in
            let line = String(rawLine)
            guard let prefix = line.first else { return nil }
            let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            let parts = body.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { return nil }
            let state: GitSubmodule.State
            switch prefix {
            case "-":
                state = .uninitialized
            case "+":
                state = .changed
            case "U":
                state = .conflicted
            default:
                state = .initialized
            }
            let details: String?
            if parts.count >= 3 {
                details = parts[2].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            } else {
                details = nil
            }
            return GitSubmodule(path: parts[1], commitID: parts[0], state: state, details: details?.isEmpty == false ? details : nil)
        }
    }

    private func selectedPatch(from patch: String, hunkIDs: Set<String>) -> String {
        filteredPatch(from: patch, hunkIDs: hunkIDs, includeSelected: true)
    }

    private func filteredPatch(from patch: String, hunkIDs: Set<String>, includeSelected: Bool) -> String {
        var output: [String] = []
        var fileHeader: [String] = []
        var includedHunks: [String] = []
        var path: String?
        var currentHunk: [String] = []
        var hunkIndex = 0

        func flushHunk() {
            guard !currentHunk.isEmpty else { return }
            if let path, hunkIDs.contains("\(path):\(hunkIndex)") == includeSelected {
                includedHunks += currentHunk
            }
            currentHunk = []
            hunkIndex += 1
        }

        func flushFile() {
            flushHunk()
            if !includedHunks.isEmpty {
                output += fileHeader
                output += includedHunks
            }
            fileHeader = []
            includedHunks = []
            path = nil
            hunkIndex = 0
        }

        for line in patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                flushFile()
                fileHeader = [line]
            } else if line.hasPrefix("@@") {
                flushHunk()
                currentHunk = [line]
            } else if !currentHunk.isEmpty {
                currentHunk.append(line)
            } else {
                fileHeader.append(line)
                if line.hasPrefix("+++ b/") {
                    path = String(line.dropFirst(6))
                } else if line.hasPrefix("+++ /dev/null"), path == nil {
                    path = fileHeader.compactMap { headerLine -> String? in
                        guard headerLine.hasPrefix("--- a/") else { return nil }
                        return String(headerLine.dropFirst(6))
                    }.last
                }
            }
        }
        flushFile()
        return output.joined(separator: "\n") + (output.isEmpty ? "" : "\n")
    }

    @discardableResult
    private func require(_ args: [String], in repo: URL, label: String) throws -> GitCommandResult {
        let result = try runner.run(args, in: repo)
        guard result.succeeded else {
            throw GitEngineError.commandFailed(command: label, exitCode: result.exitCode, stderr: result.standardError)
        }
        return result
    }
}
#endif
