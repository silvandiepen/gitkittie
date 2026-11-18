import Foundation
import GitPontCore
import GitPontGitCLI

struct FolderSyncOutcome: Equatable, Sendable {
    var folder: SyncedFolder
    var changed: Bool
    var pushed: Bool
    var message: String
}

struct LargeFileIssue: Equatable, Sendable {
    var path: String
    var byteCount: Int64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

struct GitSyncOptions: Equatable, Sendable {
    var gitAuthorName: String?
    var gitAuthorEmail: String?
    var githubToken: String?
    var sshPrivateKeyPath: String?
    var sshPrivateKeyBookmarkData: Data?

    static let defaults = GitSyncOptions(
        gitAuthorName: nil,
        gitAuthorEmail: nil,
        githubToken: nil,
        sshPrivateKeyPath: nil,
        sshPrivateKeyBookmarkData: nil
    )
}

struct GitSyncEngine: Sendable {
    private let gitRunner: any GitRunning
    private let folderAccessService: FolderAccessService
    private let now: @Sendable () -> Date

    init(
        gitRunner: any GitRunning = GitRunner(),
        folderAccessService: FolderAccessService = FolderAccessService(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.gitRunner = gitRunner
        self.folderAccessService = folderAccessService
        self.now = now
    }

    func sync(_ folder: SyncedFolder, options: GitSyncOptions = .defaults) async throws -> FolderSyncOutcome {
        try await Task.detached(priority: .utility) {
            try await self.syncSynchronously(folder, options: options)
        }.value
    }

    func repair(_ folder: SyncedFolder) async throws -> SyncedFolder {
        try await Task.detached(priority: .utility) {
            try self.folderAccessService.withSecurityScopedAccess(for: folder) { folderURL in
                guard FileManager.default.fileExists(atPath: folderURL.path) else {
                    throw GitSyncError.folderMissing(folderURL.path)
                }

                try self.abortInterruptedOperation(in: folderURL)
                try self.ensureBranch(in: folderURL, branch: folder.branch, environment: [:])

                var repaired = folder
                repaired.lastStatus = .idle
                repaired.lastError = nil
                repaired.lastCheckedAt = self.now()
                repaired.updatedAt = self.now()
                return repaired
            }
        }.value
    }

    func ignore(_ paths: [String], for folder: SyncedFolder) async throws -> SyncedFolder {
        try await Task.detached(priority: .utility) {
            try self.folderAccessService.withSecurityScopedAccess(for: folder) { folderURL in
                let normalizedPaths = paths
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && $0 != ".gitignore" }
                guard !normalizedPaths.isEmpty else { return folder }

                let ignoreURL = folderURL.appending(path: ".gitignore")
                let existing = (try? String(contentsOf: ignoreURL, encoding: .utf8)) ?? ""
                var lines = Set(existing.split(whereSeparator: \.isNewline).map(String.init))
                var additions: [String] = []
                for path in normalizedPaths {
                    let rule = "/" + path.replacingOccurrences(of: "\\", with: "\\\\")
                    if lines.insert(rule).inserted {
                        additions.append(rule)
                    }
                }

                if !additions.isEmpty {
                    var updated = existing
                    if !updated.isEmpty && !updated.hasSuffix("\n") { updated += "\n" }
                    updated += additions.sorted().joined(separator: "\n") + "\n"
                    try updated.write(to: ignoreURL, atomically: true, encoding: .utf8)
                }

                _ = try self.requireSuccess(
                    self.git(["rm", "--cached", "--ignore-unmatch", "--"] + normalizedPaths, in: folderURL, timeoutSeconds: 600),
                    failure: .gitIgnoreFailed()
                )

                var updatedFolder = folder
                updatedFolder.lastStatus = .idle
                updatedFolder.lastError = nil
                updatedFolder.updatedAt = self.now()
                return updatedFolder
            }
        }.value
    }

    func testGitHubAccess(repoUrl: String, authMode: AuthMode, options: GitSyncOptions = .defaults) async throws {
        try await Task.detached(priority: .utility) {
            let trimmedRepoUrl = repoUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedRepoUrl.isEmpty else {
                throw GitSyncError.missingRepositoryURL
            }
            let folder = SyncedFolder.create(
                name: "Access Test",
                localPath: FileManager.default.temporaryDirectory.path,
                bookmarkData: nil,
                repoUrl: trimmedRepoUrl,
                authMode: authMode
            )
            let authContext = try await self.gitAuthContext(for: folder, options: options, sshKeyURL: nil)
            let result = self.git(authContext.argumentsPrefix + ["ls-remote", "--heads", trimmedRepoUrl], in: FileManager.default.temporaryDirectory, timeoutSeconds: 45, environment: authContext.environment)
            guard result.succeeded else {
                throw GitSyncError.githubAccessFailed(result.combinedOutput)
            }
        }.value
    }

    func listRemoteBranches(repoUrl: String, authMode: AuthMode, options: GitSyncOptions = .defaults) async throws -> [String] {
        try await Task.detached(priority: .utility) {
            let trimmedRepoUrl = repoUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedRepoUrl.isEmpty else {
                throw GitSyncError.missingRepositoryURL
            }
            let folder = SyncedFolder.create(
                name: "Branch List",
                localPath: FileManager.default.temporaryDirectory.path,
                bookmarkData: nil,
                repoUrl: trimmedRepoUrl,
                authMode: authMode
            )
            let authContext = try await self.gitAuthContext(for: folder, options: options, sshKeyURL: nil)
            let result = self.git(authContext.argumentsPrefix + ["ls-remote", "--heads", trimmedRepoUrl], in: FileManager.default.temporaryDirectory, timeoutSeconds: 45, environment: authContext.environment)
            guard result.succeeded else {
                throw GitSyncError.githubAccessFailed(result.combinedOutput)
            }
            return self.branchNames(from: result.standardOutput)
        }.value
    }

    private func syncSynchronously(_ folder: SyncedFolder, options: GitSyncOptions) async throws -> FolderSyncOutcome {
        guard folder.enabled else {
            return FolderSyncOutcome(folder: folder.marked(status: .paused, message: nil, at: now()), changed: false, pushed: false, message: "Folder is paused")
        }

        guard !folder.repoUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitSyncError.missingRepositoryURL
        }

        let sshKeyAccess = try startSSHKeyAccess(options)
        defer { sshKeyAccess.stop() }
        let authContext = try await gitAuthContext(for: folder, options: options, sshKeyURL: sshKeyAccess.url)

        return try folderAccessService.withSecurityScopedAccess(for: folder) { folderURL in
            guard FileManager.default.fileExists(atPath: folderURL.path) else {
                throw GitSyncError.folderMissing(folderURL.path)
            }

            var updatedFolder = folder
            updatedFolder.localPath = folderURL.path
            updatedFolder.lastCheckedAt = now()
            updatedFolder.lastSyncAt = now()
            updatedFolder.lastError = nil

            try ensureRepository(in: folderURL, folder: updatedFolder, options: options, environment: authContext.environment)
            try ensureRemote(in: folderURL, repoUrl: updatedFolder.repoUrl, environment: authContext.environment)
            try requireRepositoryReady(in: folderURL)
            try ensureBranch(in: folderURL, branch: updatedFolder.branch, environment: authContext.environment)

            let fetch = git(
                authContext.argumentsPrefix + ["fetch", "origin", updatedFolder.branch],
                in: folderURL,
                timeoutSeconds: 1_800,
                environment: authContext.environment
            )
            if !fetch.succeeded && !isMissingUpstreamOutput(fetch.combinedOutput) {
                throw GitSyncError.gitFetchFailed(fetch.combinedOutput)
            }

            let status = try requireSuccess(git(["status", "--porcelain"], in: folderURL, environment: authContext.environment), failure: .gitStatusFailed())
            let hadLocalChanges = !status.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hadLocalChanges {
                let largeFiles = try changedLargeFiles(in: folderURL)
                guard largeFiles.isEmpty else {
                    throw GitSyncError.largeFilesBlocked(largeFiles)
                }

                _ = try requireSuccess(
                    git(["add", "-A"], in: folderURL, timeoutSeconds: 1_800, environment: authContext.environment),
                    failure: .gitAddFailed()
                )

                let commitMessage = SnapshotCommitMessage.make(date: now())
                let commit = git(["commit", "-m", commitMessage], in: folderURL, timeoutSeconds: 600, environment: authContext.environment)
                if !commit.succeeded && !commit.combinedOutput.localizedCaseInsensitiveContains("nothing to commit") {
                    throw GitSyncError.gitCommitFailed(commit.combinedOutput)
                }
            }

            let headBeforeMerge = git(["rev-parse", "HEAD"], in: folderURL).standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let remoteRef = "refs/remotes/origin/\(updatedFolder.branch)"
            let hasRemoteBranch = git(["show-ref", "--verify", "--quiet", remoteRef], in: folderURL).succeeded
            if hasRemoteBranch {
                let merge = git(["merge", "--no-edit", "origin/\(updatedFolder.branch)"], in: folderURL, timeoutSeconds: 1_800, environment: authContext.environment)
                if !merge.succeeded {
                    if FileManager.default.fileExists(atPath: folderURL.appending(path: ".git/MERGE_HEAD").path) {
                        _ = git(["merge", "--abort"], in: folderURL, timeoutSeconds: 120, environment: authContext.environment)
                    }
                    throw GitSyncError.mergeFailed(merge.combinedOutput)
                }
            }

            let headAfterMerge = git(["rev-parse", "HEAD"], in: folderURL).standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var integratedRemoteChanges = !headBeforeMerge.isEmpty && headBeforeMerge != headAfterMerge

            var push = GitCommandResult(exitCode: 1, standardOutput: "", standardError: "Push did not run.")
            for attempt in 0..<3 {
                push = git(authContext.argumentsPrefix + ["push", "-u", "origin", updatedFolder.branch], in: folderURL, timeoutSeconds: 3_600, environment: authContext.environment)
                if push.succeeded { break }
                guard attempt < 2, isRemoteAdvancedOutput(push.combinedOutput) else {
                    throw GitSyncError.gitPushFailed(push.combinedOutput)
                }

                let retryFetch = git(
                    authContext.argumentsPrefix + ["fetch", "origin", updatedFolder.branch],
                    in: folderURL,
                    timeoutSeconds: 1_800,
                    environment: authContext.environment
                )
                guard retryFetch.succeeded else {
                    throw GitSyncError.gitFetchFailed(retryFetch.combinedOutput)
                }

                let retryMerge = git(["merge", "--no-edit", "origin/\(updatedFolder.branch)"], in: folderURL, timeoutSeconds: 1_800, environment: authContext.environment)
                if !retryMerge.succeeded {
                    if FileManager.default.fileExists(atPath: folderURL.appending(path: ".git/MERGE_HEAD").path) {
                        _ = git(["merge", "--abort"], in: folderURL, timeoutSeconds: 120, environment: authContext.environment)
                    }
                    throw GitSyncError.mergeFailed(retryMerge.combinedOutput)
                }
                integratedRemoteChanges = true
            }

            updatedFolder.lastSuccessfulSyncAt = now()
            updatedFolder.updatedAt = now()
            updatedFolder.lastStatus = .synced
            let changed = hadLocalChanges || integratedRemoteChanges
            let message: String
            if hadLocalChanges && integratedRemoteChanges {
                message = "Committed local changes, integrated remote changes, and pushed"
            } else if hadLocalChanges {
                message = "Committed and pushed"
            } else if integratedRemoteChanges {
                message = "Pulled remote changes"
            } else {
                message = "Up to date"
            }
            return FolderSyncOutcome(folder: updatedFolder, changed: changed, pushed: hadLocalChanges, message: message)
        }
    }

    private func ensureRepository(in folderURL: URL, folder: SyncedFolder, options: GitSyncOptions, environment: [String: String]) throws {
        let gitDirectory = folderURL.appending(path: ".git", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: gitDirectory.path) {
            _ = try requireSuccess(git(["init"], in: folderURL, environment: environment), failure: .gitInitFailed())
        }

        if let authorName = nonEmpty(options.gitAuthorName) {
            _ = try requireSuccess(git(["config", "user.name", authorName], in: folderURL, environment: environment), failure: .gitConfigFailed("Could not save Git author name for this folder."))
        }
        if let authorEmail = nonEmpty(options.gitAuthorEmail) {
            _ = try requireSuccess(git(["config", "user.email", authorEmail], in: folderURL, environment: environment), failure: .gitConfigFailed("Could not save Git author email for this folder."))
        }

        _ = try requireSuccess(git(["config", "user.name"], in: folderURL, environment: environment), failure: .gitConfigFailed("Missing Git user.name. Add a Git author name in GitFolder Settings or configure Git globally."))
        _ = try requireSuccess(git(["config", "user.email"], in: folderURL, environment: environment), failure: .gitConfigFailed("Missing Git user.email. Add a Git author email in GitFolder Settings or configure Git globally."))
    }

    private func ensureRemote(in folderURL: URL, repoUrl: String, environment: [String: String]) throws {
        let currentRemote = git(["remote", "get-url", "origin"], in: folderURL, environment: environment)
        if currentRemote.succeeded {
            let existing = currentRemote.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard existing == repoUrl else {
                _ = try requireSuccess(git(["remote", "set-url", "origin", repoUrl], in: folderURL, environment: environment), failure: .gitRemoteFailed())
                return
            }
            return
        }

        _ = try requireSuccess(git(["remote", "add", "origin", repoUrl], in: folderURL, environment: environment), failure: .gitRemoteFailed())
    }

    private func ensureBranch(in folderURL: URL, branch: String, environment: [String: String]) throws {
        let branchName = branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "main" : branch
        let currentBranch = git(["branch", "--show-current"], in: folderURL, environment: environment)
        if currentBranch.succeeded, currentBranch.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == branchName {
            return
        }

        let checkoutExisting = git(["switch", branchName], in: folderURL, environment: environment)
        if checkoutExisting.succeeded { return }

        let remoteBranch = git(["show-ref", "--verify", "--quiet", "refs/remotes/origin/\(branchName)"], in: folderURL, environment: environment)
        let arguments = remoteBranch.succeeded
            ? ["switch", "--track", "-c", branchName, "origin/\(branchName)"]
            : ["switch", "-c", branchName]
        _ = try requireSuccess(git(arguments, in: folderURL, environment: environment), failure: .gitCheckoutFailed())
    }

    private func requireRepositoryReady(in folderURL: URL) throws {
        let gitURL = folderURL.appending(path: ".git", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: gitURL.appending(path: "index.lock").path) {
            throw GitSyncError.repositoryLocked
        }
        if FileManager.default.fileExists(atPath: gitURL.appending(path: "rebase-merge").path)
            || FileManager.default.fileExists(atPath: gitURL.appending(path: "rebase-apply").path) {
            throw GitSyncError.interruptedOperation("rebase")
        }
        if FileManager.default.fileExists(atPath: gitURL.appending(path: "MERGE_HEAD").path) {
            throw GitSyncError.interruptedOperation("merge")
        }
        if FileManager.default.fileExists(atPath: gitURL.appending(path: "CHERRY_PICK_HEAD").path) {
            throw GitSyncError.interruptedOperation("cherry-pick")
        }
        if FileManager.default.fileExists(atPath: gitURL.appending(path: "REVERT_HEAD").path) {
            throw GitSyncError.interruptedOperation("revert")
        }
    }

    private func abortInterruptedOperation(in folderURL: URL) throws {
        let gitURL = folderURL.appending(path: ".git", directoryHint: .isDirectory)
        let operations: [(String, [String])] = [
            ("rebase-merge", ["rebase", "--abort"]),
            ("rebase-apply", ["rebase", "--abort"]),
            ("MERGE_HEAD", ["merge", "--abort"]),
            ("CHERRY_PICK_HEAD", ["cherry-pick", "--abort"]),
            ("REVERT_HEAD", ["revert", "--abort"])
        ]
        for (marker, arguments) in operations where FileManager.default.fileExists(atPath: gitURL.appending(path: marker).path) {
            _ = try requireSuccess(git(arguments, in: folderURL, timeoutSeconds: 300), failure: .repairFailed())
            break
        }
        if FileManager.default.fileExists(atPath: gitURL.appending(path: "index.lock").path) {
            throw GitSyncError.repositoryLocked
        }
    }

    private func changedLargeFiles(in folderURL: URL) throws -> [LargeFileIssue] {
        let result = try requireSuccess(
            git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: folderURL, timeoutSeconds: 600),
            failure: .gitStatusFailed()
        )
        let entries = result.standardOutput.split(separator: "\0", omittingEmptySubsequences: true)
        var issues: [LargeFileIssue] = []
        var skipNextRenameSource = false
        for rawEntry in entries {
            if skipNextRenameSource {
                skipNextRenameSource = false
                continue
            }
            let entry = String(rawEntry)
            guard entry.count > 3 else { continue }
            let status = String(entry.prefix(2))
            let path = String(entry.dropFirst(3))
            if status.contains("R") || status.contains("C") {
                skipNextRenameSource = true
            }
            let fileURL = folderURL.appending(path: path)
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize, Int64(size) >= 100_000_000 else { continue }
            issues.append(LargeFileIssue(path: path, byteCount: Int64(size)))
        }
        return issues.sorted { $0.byteCount > $1.byteCount }
    }

    private func git(_ arguments: [String], in workingDirectory: URL, timeoutSeconds: TimeInterval = 30, environment: [String: String] = [:]) -> GitCommandResult {
        do {
            return try gitRunner.run(arguments, in: workingDirectory, timeoutSeconds: timeoutSeconds, environment: environment)
        } catch {
            return GitCommandResult(exitCode: 1, standardOutput: "", standardError: error.localizedDescription)
        }
    }

    private func startSSHKeyAccess(_ options: GitSyncOptions) throws -> ScopedURLAccess {
        guard let bookmarkData = options.sshPrivateKeyBookmarkData else {
            if let path = nonEmpty(options.sshPrivateKeyPath) {
                return ScopedURLAccess(url: URL(fileURLWithPath: path), didStart: false)
            }
            return ScopedURLAccess(url: nil, didStart: false)
        }

        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if stale {
            throw FolderAccessError.staleBookmark
        }
        let didStart = url.startAccessingSecurityScopedResource()
        return ScopedURLAccess(url: url, didStart: didStart)
    }

    private func gitEnvironment(sshKeyURL: URL?) -> [String: String] {
        guard let sshKeyURL else { return [:] }
        return [
            "GIT_SSH_COMMAND": "ssh -i \(shellQuoted(sshKeyURL.path)) -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
        ]
    }

    private func gitAuthContext(for folder: SyncedFolder, options: GitSyncOptions, sshKeyURL: URL?) async throws -> GitAuthContext {
        switch folder.authModeValue {
        case .githubToken:
            guard let token = nonEmpty(options.githubToken) else {
                throw GitSyncError.missingGitHubToken
            }
            return try await .githubToken(token, repoUrl: folder.repoUrl)
        case .ssh:
            return GitAuthContext(argumentsPrefix: [], environment: gitEnvironment(sshKeyURL: sshKeyURL))
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func requireSuccess(_ result: GitCommandResult, failure: GitSyncError) throws -> GitCommandResult {
        guard result.succeeded else {
            switch failure {
            case .gitConfigFailed:
                throw failure
            default:
                throw failure.withDetails(result.combinedOutput)
            }
        }
        return result
    }

    private func isMissingUpstreamOutput(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("couldn't find remote ref")
            || output.localizedCaseInsensitiveContains("fatal: couldn't find remote ref")
            || output.localizedCaseInsensitiveContains("no such ref was fetched")
    }

    private func isRemoteAdvancedOutput(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("non-fast-forward")
            || output.localizedCaseInsensitiveContains("fetch first")
            || output.localizedCaseInsensitiveContains("cannot lock ref")
            || output.localizedCaseInsensitiveContains("failed to push some refs")
    }

    private func branchNames(from lsRemoteOutput: String) -> [String] {
        let prefix = "refs/heads/"
        return lsRemoteOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                guard let ref = line.split(separator: "\t").last else { return nil }
                guard ref.hasPrefix(prefix) else { return nil }
                return String(ref.dropFirst(prefix.count))
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

enum GitSyncError: LocalizedError, Equatable, Sendable {
    case missingRepositoryURL
    case missingGitHubToken
    case folderMissing(String)
    case gitInitFailed(String = "")
    case gitConfigFailed(String)
    case gitRemoteFailed(String = "")
    case gitCheckoutFailed(String = "")
    case gitStatusFailed(String = "")
    case gitFetchFailed(String)
    case gitAddFailed(String = "")
    case gitIgnoreFailed(String = "")
    case gitCommitFailed(String)
    case mergeFailed(String)
    case gitPushFailed(String)
    case githubAccessFailed(String)
    case interruptedOperation(String)
    case repositoryLocked
    case repairFailed(String = "")
    case largeFilesBlocked([LargeFileIssue])

    var errorDescription: String? {
        switch self {
        case .missingRepositoryURL:
            return "Add a GitHub repository URL before syncing."
        case .missingGitHubToken:
            return "Add a GitHub token in Settings before syncing this folder."
        case .folderMissing(let path):
            return "Folder not found: \(path)"
        case .gitInitFailed(let details):
            return "Could not initialize Git repository.\(suffix(details))"
        case .gitConfigFailed(let details):
            return details
        case .gitRemoteFailed(let details):
            return "Could not configure GitHub remote.\(suffix(details))"
        case .gitCheckoutFailed(let details):
            return "Could not switch to the configured branch.\(suffix(details))"
        case .gitStatusFailed(let details):
            return "Could not check folder changes.\(suffix(details))"
        case .gitFetchFailed(let details):
            return "Could not fetch remote changes.\(suffix(details))"
        case .gitAddFailed(let details):
            return "Could not stage folder changes.\(suffix(details))"
        case .gitIgnoreFailed(let details):
            return "Could not exclude the selected files.\(suffix(details))"
        case .gitCommitFailed(let details):
            return "Could not create snapshot commit.\(suffix(details))"
        case .mergeFailed(let details):
            return "Remote changes conflict with local changes. GitFolder aborted the merge and left the branch attached.\(suffix(details))"
        case .gitPushFailed(let details):
            return "Could not push snapshot to GitHub.\(suffix(details))"
        case .githubAccessFailed(let details):
            return "Could not access the GitHub repository.\(suffix(details))"
        case .interruptedOperation(let operation):
            return "An interrupted Git \(operation) left this repository unfinished."
        case .repositoryLocked:
            return "This repository is locked by another Git operation."
        case .repairFailed(let details):
            return "Could not repair the interrupted Git operation.\(suffix(details))"
        case .largeFilesBlocked(let files):
            let summary = files.prefix(3).map { "\($0.path) (\($0.formattedSize))" }.joined(separator: ", ")
            return "GitFolder found \(files.count) changed file\(files.count == 1 ? "" : "s") at or above GitHub's 100 MB limit: \(summary)"
        }
    }

    var code: String {
        switch self {
        case .missingRepositoryURL: return "missing_repository_url"
        case .missingGitHubToken: return "missing_github_token"
        case .folderMissing: return "folder_missing"
        case .gitInitFailed: return "git_init_failed"
        case .gitConfigFailed: return "git_config_failed"
        case .gitRemoteFailed: return "git_remote_failed"
        case .gitCheckoutFailed: return "git_checkout_failed"
        case .gitStatusFailed: return "git_status_failed"
        case .gitFetchFailed: return "git_fetch_failed"
        case .gitAddFailed: return "git_add_failed"
        case .gitIgnoreFailed: return "git_ignore_failed"
        case .gitCommitFailed: return "git_commit_failed"
        case .mergeFailed: return "merge_failed"
        case .gitPushFailed: return "git_push_failed"
        case .githubAccessFailed: return "github_access_failed"
        case .interruptedOperation: return "interrupted_operation"
        case .repositoryLocked: return "repository_locked"
        case .repairFailed: return "repair_failed"
        case .largeFilesBlocked: return "large_files_blocked"
        }
    }

    func userFacingError() -> UserFacingError {
        UserFacingError(
            code: code,
            title: "Sync failed",
            message: errorDescription ?? "GitFolder could not sync this folder.",
            recoverySuggestion: recoverySuggestion,
            technicalDetailsLogId: nil,
            affectedPaths: affectedPaths
        )
    }

    private var affectedPaths: [String]? {
        guard case .largeFilesBlocked(let files) = self else { return nil }
        return files.map(\.path)
    }

    var recoverySuggestion: String? {
        switch self {
        case .missingRepositoryURL:
            return "Open Settings and add a GitHub repository URL for this folder."
        case .missingGitHubToken:
            return "Open Settings and paste a fine-grained GitHub token."
        case .gitConfigFailed:
            return "Run `git config --global user.name` and `git config --global user.email`, then try again."
        case .gitPushFailed, .gitFetchFailed, .gitRemoteFailed, .githubAccessFailed:
            return "Check that the repository exists and your GitHub access works."
        case .mergeFailed:
            return "Review the conflicting files, then sync again. GitFolder did not leave a merge in progress."
        case .interruptedOperation:
            return "Use Repair & Sync to abort the interrupted operation, restore the configured branch, and retry safely."
        case .repositoryLocked:
            return "Wait for the other Git operation to finish, then try again."
        case .largeFilesBlocked:
            return "Exclude these files in .gitignore, or move them to Git LFS, before syncing."
        case .folderMissing:
            return "Reconnect or remove this folder in Settings."
        default:
            return "Open the folder in Terminal, run Git manually once, then try Sync Now again."
        }
    }

    private func suffix(_ details: String) -> String {
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : " \(trimmed)"
    }

    func withDetails(_ details: String) -> GitSyncError {
        switch self {
        case .gitInitFailed: return .gitInitFailed(details)
        case .gitRemoteFailed: return .gitRemoteFailed(details)
        case .gitCheckoutFailed: return .gitCheckoutFailed(details)
        case .gitStatusFailed: return .gitStatusFailed(details)
        case .gitFetchFailed: return .gitFetchFailed(details)
        case .gitAddFailed: return .gitAddFailed(details)
        case .gitIgnoreFailed: return .gitIgnoreFailed(details)
        case .gitCommitFailed: return .gitCommitFailed(details)
        case .mergeFailed: return .mergeFailed(details)
        case .gitPushFailed: return .gitPushFailed(details)
        case .githubAccessFailed: return .githubAccessFailed(details)
        case .repairFailed: return .repairFailed(details)
        default: return self
        }
    }
}

struct GitAuthContext: Equatable, Sendable {
    var argumentsPrefix: [String]
    var environment: [String: String]

    static func githubToken(_ token: String, repoUrl: String) async throws -> GitAuthContext {
        guard let remoteURL = URL(string: repoUrl) else {
            throw GitSyncError.missingRepositoryURL
        }

        let connectionStore = InMemoryConnectionStore()
        let credentialStore = InMemoryCredentialStore()
        let connectionID = "gitfolder-github"
        let now = Date()
        let connection = GitConnection(
            id: connectionID,
            instance: .github,
            accountID: "github",
            accountLogin: "x-access-token",
            authMethod: .personalAccessToken,
            createdAt: now,
            updatedAt: now
        )
        await connectionStore.save(connection)
        await credentialStore.save(GitCredential(accessToken: token), for: connectionID)

        let gitPont = GitPont(
            providers: [],
            connectionStore: connectionStore,
            credentialStore: credentialStore,
            httpClient: URLSessionHTTPClient()
        )
        let context = try await gitPont.gitCredentialContext(forRemoteURL: remoteURL, preferredConnectionID: connectionID)
        return GitAuthContext(argumentsPrefix: context.argumentsPrefix, environment: context.environment)
    }
}

struct SnapshotCommitMessage {
    static func make(date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return "GitFolder snapshot \(formatter.string(from: date))"
    }
}

private struct ScopedURLAccess: Sendable {
    var url: URL?
    var didStart: Bool

    func stop() {
        if didStart {
            url?.stopAccessingSecurityScopedResource()
        }
    }
}

private extension GitCommandResult {
    var combinedOutput: String {
        [standardOutput, standardError]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

private extension SyncedFolder {
    func marked(status: SyncStatus, message: String?, at date: Date) -> SyncedFolder {
        var copy = self
        copy.lastStatus = status
        copy.updatedAt = date
        copy.lastCheckedAt = date
        if let message {
            copy.lastError = UserFacingError(code: "status", title: message, message: message, recoverySuggestion: nil, technicalDetailsLogId: nil)
        }
        return copy
    }
}
