import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One change a split can move: a hunk of a commit, numbered for the model.
public struct CommitSplitCandidate: Sendable, Equatable, Identifiable {
    public let id: Int
    /// `GitHunk.id` of the hunk this stands for.
    public let hunkID: String
    public let path: String
    /// The hunk's changed lines, clipped, so the model can see what it does.
    public let excerpt: String

    public init(id: Int, hunkID: String, path: String, excerpt: String) {
        self.id = id
        self.hunkID = hunkID
        self.path = path
        self.excerpt = excerpt
    }

    /// One candidate per hunk of `diffs`, numbered from 1.
    public static func candidates(from diffs: [GitFileDiff], linesPerHunk: Int = 8) -> [CommitSplitCandidate] {
        var number = 0
        return diffs.flatMap { file in
            file.hunks.compactMap { hunk -> CommitSplitCandidate? in
                let changed = hunk.lines.filter { $0.hasPrefix("+") || $0.hasPrefix("-") }
                guard !changed.isEmpty else { return nil }
                number += 1
                return CommitSplitCandidate(
                    id: number,
                    hunkID: hunk.id,
                    path: file.path,
                    excerpt: changed.prefix(linesPerHunk).joined(separator: "\n"))
            }
        }
    }
}

/// A commit a split would make: its message and the hunks it takes.
public struct SuggestedCommit: Sendable, Equatable, Identifiable {
    public let id: Int
    public let message: String
    public let hunkIDs: [String]

    public init(id: Int, message: String, hunkIDs: [String]) {
        self.id = id
        self.message = message
        self.hunkIDs = hunkIDs
    }
}

public enum CommitSplitPlan {
    /// Makes whatever the model returned into a usable plan: every change in exactly one
    /// commit (the first group that names it), unknown numbers dropped, empty groups dropped,
    /// changes nobody named collected into a last commit. Fewer than two commits is no split.
    public static func normalize(
        groups: [(message: String, changes: [Int])],
        candidates: [CommitSplitCandidate]
    ) -> [SuggestedCommit] {
        let byNumber = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        var claimed = Set<Int>()
        var result: [SuggestedCommit] = []
        for group in groups {
            let numbers = group.changes.filter { byNumber[$0] != nil && !claimed.contains($0) }
            var seen = Set<Int>()
            let unique = numbers.filter { seen.insert($0).inserted }
            guard !unique.isEmpty else { continue }
            claimed.formUnion(unique)
            let message = group.message.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(SuggestedCommit(
                id: result.count + 1,
                message: message.isEmpty ? "Split changes" : message,
                hunkIDs: unique.sorted().compactMap { byNumber[$0]?.hunkID }))
        }
        let rest = candidates.filter { !claimed.contains($0.id) }
        if !rest.isEmpty {
            result.append(SuggestedCommit(id: result.count + 1, message: "Remaining changes", hunkIDs: rest.map(\.hunkID)))
        }
        return result.count >= 2 ? result : []
    }
}

extension OnDeviceAI {
    /// Asks the on-device model how a commit's hunks group into separate commits, each with
    /// a message. Returns no commits when it sees one concern only.
    public static func suggestCommitSplit(
        _ candidates: [CommitSplitCandidate],
        commitMessage: String
    ) async throws -> [SuggestedCommit] {
        if let reason = unavailableReason { throw AIPontMagicError.onDeviceUnavailable(reason) }
        guard candidates.count >= 2 else { return [] }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let session = LanguageModelSession(instructions: """
                You help split a git commit that mixes several unrelated changes into smaller \
                commits. Group the numbered changes by purpose, not by file: changes in different \
                files that serve one purpose go together (a new button and the style for that \
                button), and two changes in the same file go apart when they do different things \
                (a navigation link and an analytics script). Every change number goes in exactly \
                one group. Give each group a commit message that says what the change does for the \
                product, as a short imperative subject under 72 characters, without file names: \
                'Add a sign-up button to the header', not 'Update index.html'. If all changes serve \
                one purpose, return a single group with every number.
                """)
            let listing = candidates.map { "Change \($0.id) (in \($0.path)):\n\($0.excerpt)" }.joined(separator: "\n\n")
            let prompt = "The commit's message: \(commitMessage)\n\nThe changes:\n\n\(clipped(listing, to: 5000))"
            // Greedy: the same commit gets the same suggestion every time it is asked.
            let plan = try await session.respond(
                to: prompt, generating: OnDeviceSplitPlan.self, options: GenerationOptions(sampling: .greedy)
            ).content
            return CommitSplitPlan.normalize(
                groups: plan.groups.map { (message: $0.message, changes: $0.changes) },
                candidates: candidates)
        }
        #endif
        throw AIPontMagicError.onDeviceUnavailable("The on-device model is not available.")
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
@Generable
struct OnDeviceSplitPlan {
    @Guide(description: "The commits to make, in the order they should be made")
    var groups: [OnDeviceSplitGroup]
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct OnDeviceSplitGroup {
    @Guide(description: "The commit message: an imperative subject line under 72 characters, such as 'Fix the date parser' or 'Add a dark theme'")
    var message: String
    @Guide(description: "The numbers of the changes that go in this commit")
    var changes: [Int]
}
#endif
