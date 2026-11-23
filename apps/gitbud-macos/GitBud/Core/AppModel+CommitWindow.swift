import Foundation
import GitKittieKit

/// Everything the commit window shows: the commit, its files, and its diff as asked for.
public struct GitBudCommitDocument: Sendable, Equatable {
    public let commit: GitCommitNode?
    public let files: [GitChangedFile]
    public let diffs: [GitFileDiff]

    /// Lines added and removed per file path.
    public var stats: [String: (added: Int, removed: Int)] {
        var result: [String: (added: Int, removed: Int)] = [:]
        for diff in diffs {
            let lines = diff.hunks.flatMap(\.lines)
            result[diff.path] = (lines.filter { $0.hasPrefix("+") }.count, lines.filter { $0.hasPrefix("-") }.count)
        }
        return result
    }

    public static func == (lhs: GitBudCommitDocument, rhs: GitBudCommitDocument) -> Bool {
        lhs.commit == rhs.commit && lhs.files == rhs.files && lhs.diffs == rhs.diffs
    }
}

extension AppModel {
    /// The commit with this id, from the loaded history.
    public func commit(withID id: String) -> GitCommitNode? {
        commits.first { $0.id == id }
    }

    /// Loads a commit for its own window. The window owns what it shows; this only reads.
    public func commitDocument(_ commitID: String, options: GitDiffOptions) async throws -> GitBudCommitDocument {
        guard let repositoryURL else { throw GitRewriteError.emptySelection }
        async let files = gitHistory.changedFiles(at: repositoryURL, commit: commitID)
        async let diffs = gitHistory.diff(at: repositoryURL, commit: commitID, options: options)
        return GitBudCommitDocument(commit: commit(withID: commitID), files: try await files, diffs: try await diffs)
    }

    /// Puts the chosen changes of a commit into the working copy (`reverse` undoes them).
    /// History and the index are left alone: the result is ordinary changes to review.
    /// Returns whether it worked; a failure is reported in `errorMessage`.
    @discardableResult
    public func applyCommitChanges(
        of commitID: String,
        _ diffs: [GitFileDiff],
        selection: GitChangeSelection,
        reverse: Bool
    ) async -> Bool {
        guard let repositoryURL else { return false }
        let count = selection.count(in: diffs)
        do {
            try await gitHistory.applyCommitChanges(
                at: repositoryURL, commit: commitID, diffs: diffs, selection: selection, reverse: reverse)
            await reload(statusMessage: reverse
                ? "Undid \(count) changed line\(count == 1 ? "" : "s") in the working copy. Review them in Changes."
                : "Applied \(count) changed line\(count == 1 ? "" : "s") to the working copy. Review them in Changes.")
            return true
        } catch let error as GitRewriteError {
            errorMessage = error.localizedDescription
            return false
        } catch {
            errorMessage = "Those changes could not be put in your files, so nothing was changed.\n\n\(error.localizedDescription)"
            return false
        }
    }

    // MARK: - On-device Magic

    /// Why Apple's on-device model can't be used on this Mac, or nil when it can.
    public var onDeviceMagicUnavailableReason: String? { OnDeviceAI.unavailableReason }

    /// Asks the on-device model how this commit splits into separate commits.
    public func suggestSplit(of commitID: String) async throws -> [SuggestedCommit] {
        guard let repositoryURL else { return [] }
        // The standard diff, so the hunk ids match the ones the split uses.
        let diffs = try await gitHistory.diff(at: repositoryURL, commit: commitID, options: .standard)
        let message = commit(withID: commitID).map { [$0.subject, $0.body].joined(separator: "\n\n") } ?? ""
        return try await OnDeviceAI.suggestCommitSplit(CommitSplitCandidate.candidates(from: diffs), commitMessage: message)
    }

    /// Lines a suggested commit up for the split: focuses its commit, ticks its hunks, and puts
    /// its message in the draft. The split itself still waits for the user.
    public func prepareSplit(_ suggestion: SuggestedCommit, of commitID: String) async {
        workspaceMode = .history
        // Loaded first, so the ticks below survive the refresh of the commit's hunks.
        if let commit = commit(withID: commitID), focusedCommitID != commitID {
            await focusCommit(commit)
        }
        selectedSplitPaths = []
        selectedSplitHunkIDs = Set(suggestion.hunkIDs)
        magicDraft = suggestion.message
        statusMessage = "Ready to split off “\(suggestion.message)”. Choose Split to make it its own commit."
    }
}
