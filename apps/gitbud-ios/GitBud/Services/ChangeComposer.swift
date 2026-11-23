import Foundation
import GitKittieKit
import GitPontCore

/// Turns chosen lines of a commit into a pull request: the iOS counterpart of "apply to
/// working copy" on the Mac, since there is no working copy here.
///
/// Each file is a three-way merge, read from the host: the file as the commit had it (base),
/// that file with the chosen lines picked or undone (theirs), and the file on the branch
/// the pull request targets (ours). Edits made on that branch since — even on the very next
/// line — are kept; only when the chosen lines themselves changed since is nothing made.
struct ChangeComposer {
    let provider: any GitProvider
    let context: GitProviderRequestContext
    let repository: GitRepositoryReference

    enum ComposeError: LocalizedError, Equatable {
        case nothingChosen
        case conflict([String])

        var errorDescription: String? {
            switch self {
            case .nothingChosen:
                return "Choose changed lines first."
            case let .conflict(paths):
                return "The chosen lines were changed since on the target branch in \(paths.joined(separator: ", ")), so no pull request was made."
            }
        }
    }

    /// The new content of every file the chosen lines touch, on top of `target`.
    func operations(
        commit: GitCommitDetail,
        diffs: [GitFileDiff],
        selection: GitChangeSelection,
        reverse: Bool,
        onto target: String
    ) async throws -> [GitFileOperation] {
        var operations: [GitFileOperation] = []
        var conflicts: [String] = []
        for diff in diffs {
            let patch = GitPatchBuilder.patch(for: diff, selection: selection, reverse: reverse)
            guard !patch.isEmpty else { continue }

            // base: the file on the side of the commit the change starts from.
            let baseMissing = reverse ? diff.isDeletedFile : diff.isNewFile
            let baseRef = reverse ? commit.summary.sha : commit.summary.parentSHAs.first
            let base: String? = baseMissing || baseRef == nil
                ? nil
                : try await text(of: reverse ? diff.path : (diff.oldPath ?? diff.path), at: baseRef!)
            let theirs = try GitPatchBuilder.applying(patch, to: base)
            let ours = try await text(of: diff.path, at: target)

            let result: String?
            if ours == base {
                result = theirs
            } else if ours == theirs {
                continue
            } else if let ours, let base, let theirs, let merged = GitLineMerge.merge(base: base, ours: ours, theirs: theirs) {
                result = merged
            } else {
                conflicts.append(diff.path)
                continue
            }
            // The branch already reads this way: nothing to commit for this file.
            guard result != ours else { continue }
            operations.append(result.map { .write(diff.path, Data($0.utf8)) } ?? .delete(diff.path))
        }
        guard conflicts.isEmpty else { throw ComposeError.conflict(conflicts) }
        guard !operations.isEmpty else { throw ComposeError.nothingChosen }
        return operations
    }

    /// Branch from `target`, commit the change there, and open the pull request.
    func openPullRequest(
        commit: GitCommitDetail,
        diffs: [GitFileDiff],
        selection: GitChangeSelection,
        reverse: Bool,
        target: String,
        branchName: String,
        title: String,
        body: String
    ) async throws -> GitPullRequest {
        // Worked out before anything is written, so a conflict leaves the host untouched.
        let operations = try await operations(commit: commit, diffs: diffs, selection: selection, reverse: reverse, onto: target)
        _ = try await provider.createBranch(
            GitCreateBranchRequest(repository: repository, name: branchName, fromRef: target), context: context)
        let message = body.isEmpty ? title : "\(title)\n\n\(body)"
        _ = try await provider.commitFiles(
            GitMultiFileCommit(repository: repository, branch: branchName, message: message, operations: operations),
            context: context)
        return try await provider.createPullRequest(
            GitPullRequestRequest(repository: repository, title: title, body: body, sourceBranch: branchName, targetBranch: target),
            context: context)
    }

    /// A file's text at a ref; nil when the file is not there.
    private func text(of path: String, at ref: String) async throws -> String? {
        do {
            let file = try await provider.readFile(GitFileReference(repository: repository, path: path, ref: ref), context: context)
            return String(decoding: file.content, as: UTF8.self)
        } catch GitPontError.notFound {
            return nil
        }
    }
}
