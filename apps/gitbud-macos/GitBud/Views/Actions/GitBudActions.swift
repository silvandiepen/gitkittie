import GitBudCore
import GitKittieKit
import SwiftUI

/// The verb registry. Every git operation the user can invoke is declared here once,
/// with the conditions under which it makes sense. Menus, toolbars, and the ⌘K palette
/// all read from these functions.
@MainActor
enum GitBudActions {
    // MARK: - Commits

    static func commit(_ commit: GitCommitNode, model: AppModel) -> [GitBudAction] {
        let selectionCount = model.selectedCommitIDs.count
        let dirty = !model.worktreeFiles.isEmpty
        let busy = model.isRewriting || model.hasConflicts
        let dirtyReason = "Commit or stash your changes first"
        let busyReason = model.hasConflicts ? "Resolve conflicts first" : "A rewrite is already running"

        var actions: [GitBudAction] = [
            GitBudAction(
                id: "commit.copySHA",
                title: "Copy SHA",
                icon: "doc.on.doc",
                perform: { _ in gitBudCopyToPasteboard(commit.id) }
            ),
            GitBudAction(
                id: "commit.branch",
                title: "Create Branch Here…",
                icon: "arrow.triangle.branch",
                interaction: .input(
                    title: "Branch from \(commit.shortID)",
                    placeholder: "feature/my-branch",
                    defaultValue: "",
                    verb: "Create Branch"
                ),
                perform: { name in
                    model.focusedCommitID = commit.id
                    model.newBranchName = name
                    model.createBranchFromSelectedCommit()
                }
            )
            .disabled(when: dirty, reason: dirtyReason),
            GitBudAction(
                id: "commit.tag",
                title: "Tag…",
                icon: "tag",
                interaction: .input(
                    title: "Tag \(commit.shortID)",
                    placeholder: "v1.0.0",
                    defaultValue: "",
                    verb: "Create Tag"
                ),
                perform: { name in
                    model.focusedCommitID = commit.id
                    model.newTagName = name
                    model.createTagFromSelectedCommit()
                }
            )
            .disabled(when: dirty, reason: dirtyReason)
        ]

        actions.append(
            GitBudAction(
                id: "commit.rewriteMessage",
                title: "Rewrite Message…",
                icon: "text.cursor",
                interaction: .input(
                    title: "Rewrite message",
                    placeholder: "Commit message",
                    defaultValue: commit.subject,
                    verb: "Rewrite"
                ),
                perform: { message in
                    model.focusedCommitID = commit.id
                    model.magicDraft = message
                    model.editHeadCommitMessage()
                }
            )
            .disabled(when: dirty, reason: dirtyReason)
            .disabled(when: busy, reason: busyReason)
        )

        if selectionCount > 1 {
            actions.append(
                GitBudAction(
                    id: "commit.squash",
                    title: "Squash \(selectionCount) Commits",
                    icon: "arrow.down.forward.and.arrow.up.backward",
                    interaction: .confirm(
                        title: "Squash \(selectionCount) commits?",
                        message: "They become one commit. GitBud saves a safety branch first, so this can be undone.",
                        verb: "Squash"
                    ),
                    perform: { _ in model.squashSelectedCommits() }
                )
                .disabled(when: dirty, reason: dirtyReason)
                .disabled(when: busy, reason: busyReason)
            )
            actions.append(
                GitBudAction(
                    id: "commit.reverseOrder",
                    title: "Reverse Order of \(selectionCount)",
                    icon: "arrow.up.arrow.down",
                    interaction: .confirm(
                        title: "Reverse \(selectionCount) commits?",
                        message: "The selected commits are replayed in the opposite order.",
                        verb: "Reverse"
                    ),
                    perform: { _ in model.reverseSelectedCommitOrder() }
                )
                .disabled(when: dirty, reason: dirtyReason)
                .disabled(when: busy, reason: busyReason)
            )
        }

        actions.append(contentsOf: [
            GitBudAction(
                id: "commit.moveEarlier",
                title: "Move Earlier",
                icon: "arrow.up",
                perform: { _ in
                    model.focusedCommitID = commit.id
                    model.moveFocusedCommitEarlier()
                }
            )
            .disabled(when: selectionCount < 2, reason: "Select at least two commits"),
            GitBudAction(
                id: "commit.moveLater",
                title: "Move Later",
                icon: "arrow.down",
                perform: { _ in
                    model.focusedCommitID = commit.id
                    model.moveFocusedCommitLater()
                }
            )
            .disabled(when: selectionCount < 2, reason: "Select at least two commits"),
            GitBudAction(
                id: "commit.applyOrder",
                title: "Apply Planned Order",
                icon: "checklist",
                interaction: .confirm(
                    title: "Apply the planned order?",
                    message: "The selected commits are rewritten into the order shown in the detail pane.",
                    verb: "Apply"
                ),
                perform: { _ in model.applyPlannedCommitOrder() }
            )
            .disabled(when: model.rewritePreview == nil, reason: "Reorder some commits first")
            .disabled(when: dirty, reason: dirtyReason),
            GitBudAction(
                id: "commit.split",
                title: "Split by Selected Files…",
                icon: "square.split.2x1",
                perform: { _ in
                    model.focusedCommitID = commit.id
                    model.splitHeadCommitBySelectedFiles()
                }
            )
            .disabled(
                when: model.selectedSplitPaths.isEmpty && model.selectedSplitHunkIDs.isEmpty,
                reason: "Tick files or hunks in the detail pane first"
            )
            .disabled(when: dirty, reason: dirtyReason)
            .disabled(when: busy, reason: busyReason),
            GitBudAction(
                id: "commit.revert",
                title: "Revert",
                icon: "arrow.uturn.backward.circle",
                interaction: .confirm(
                    title: "Revert \(commit.shortID)?",
                    message: "A new commit is added that undoes this one. History is not rewritten.",
                    verb: "Revert"
                ),
                perform: { _ in
                    model.focusedCommitID = commit.id
                    model.revertSelectedCommit()
                }
            )
            .disabled(when: dirty, reason: dirtyReason)
            .disabled(when: busy, reason: busyReason),
            GitBudAction(
                id: "commit.cherryPick",
                title: "Cherry-pick onto Current Branch",
                icon: "arrow.down.doc",
                interaction: .confirm(
                    title: "Cherry-pick \(commit.shortID)?",
                    message: "This commit's changes are replayed on top of the current branch.",
                    verb: "Cherry-pick"
                ),
                perform: { _ in
                    model.focusedCommitID = commit.id
                    model.cherryPickSelectedCommit()
                }
            )
            .disabled(when: dirty, reason: dirtyReason)
            .disabled(when: busy, reason: busyReason),
            GitBudAction(
                id: "commit.drop",
                title: "Drop",
                icon: "trash",
                isDestructive: true,
                interaction: .confirm(
                    title: "Drop \(commit.shortID)?",
                    message: "\"\(commit.subject)\" is removed from history. GitBud saves a safety branch first.",
                    verb: "Drop"
                ),
                perform: { _ in
                    model.focusedCommitID = commit.id
                    model.dropSelectedCommit()
                }
            )
            .disabled(when: dirty, reason: dirtyReason)
            .disabled(when: busy, reason: busyReason),
            GitBudAction(
                id: "commit.reset",
                title: "Reset Branch Here…",
                icon: "arrow.counterclockwise.circle",
                isDestructive: true,
                interaction: .confirm(
                    title: "Reset to \(commit.shortID)?",
                    message: "The current branch moves back to this commit. Later changes stay in your working tree.",
                    verb: "Reset"
                ),
                perform: { _ in
                    model.focusedCommitID = commit.id
                    model.resetCurrentBranchToSelectedCommit()
                }
            )
            .disabled(when: dirty, reason: dirtyReason)
            .disabled(when: busy, reason: busyReason)
        ])

        return actions
    }

    // MARK: - Branches

    static func branch(_ branch: GitBranch, model: AppModel) -> [GitBudAction] {
        let dirty = !model.worktreeFiles.isEmpty
        let dirtyReason = "Commit or stash your changes first"
        let busy = model.isChangingBranch || model.isRunningBranchOperation || model.hasConflicts
        let busyReason = model.hasConflicts ? "Resolve conflicts first" : "A branch operation is already running"

        return [
            GitBudAction(
                id: "branch.checkout",
                title: branch.kind == .local ? "Switch to Branch" : "Check Out as Local Branch",
                icon: "arrow.right.circle",
                perform: { _ in model.checkoutBranch(branch) }
            )
            .disabled(when: branch.kind == .local && branch.isCurrent, reason: "Already on this branch")
            .disabled(when: dirty, reason: dirtyReason)
            .disabled(when: busy, reason: busyReason),
            GitBudAction(
                id: "branch.copyName",
                title: "Copy Name",
                icon: "doc.on.doc",
                perform: { _ in gitBudCopyToPasteboard(branch.shortName) }
            ),
            GitBudAction(
                id: "branch.merge",
                title: "Merge into Current",
                icon: "arrow.triangle.merge",
                interaction: .confirm(
                    title: "Merge \(branch.shortName)?",
                    message: "Its commits are merged into \(model.branchSummary?.currentBranch ?? "the current branch").",
                    verb: "Merge"
                ),
                perform: { _ in
                    model.selectBranchOperationTarget(branch)
                    model.mergeSelectedBranchIntoCurrent()
                }
            )
            .disabled(when: branch.isCurrent, reason: "Cannot merge a branch into itself")
            .disabled(when: dirty, reason: dirtyReason)
            .disabled(when: busy, reason: busyReason),
            GitBudAction(
                id: "branch.rebase",
                title: "Rebase Current onto This",
                icon: "arrow.triangle.2.circlepath",
                interaction: .confirm(
                    title: "Rebase onto \(branch.shortName)?",
                    message: "The current branch's commits are replayed on top of \(branch.shortName).",
                    verb: "Rebase"
                ),
                perform: { _ in
                    model.selectBranchOperationTarget(branch)
                    model.rebaseCurrentBranchOntoSelectedBranch()
                }
            )
            .disabled(when: branch.isCurrent, reason: "Cannot rebase a branch onto itself")
            .disabled(when: dirty, reason: dirtyReason)
            .disabled(when: busy, reason: busyReason),
            GitBudAction(
                id: "branch.rename",
                title: "Rename…",
                icon: "pencil",
                interaction: .input(
                    title: "Rename \(branch.shortName)",
                    placeholder: "New name",
                    defaultValue: branch.shortName,
                    verb: "Rename"
                ),
                perform: { name in
                    model.selectBranchOperationTarget(branch)
                    model.renameBranchName = name
                    model.renameSelectedBranch()
                }
            )
            .disabled(when: branch.kind == .remote, reason: "Remote branches are renamed on the provider")
            .disabled(when: dirty, reason: dirtyReason)
            .disabled(when: busy, reason: busyReason),
            GitBudAction(
                id: "branch.delete",
                title: "Delete",
                icon: "trash",
                isDestructive: true,
                interaction: .confirm(
                    title: "Delete \(branch.shortName)?",
                    message: "The branch ref is removed. Commits only reachable from it become unreferenced.",
                    verb: "Delete"
                ),
                perform: { _ in
                    model.selectBranchOperationTarget(branch)
                    model.deleteSelectedBranch()
                }
            )
            .disabled(when: branch.isCurrent, reason: "Cannot delete the branch you are on")
            .disabled(when: dirty, reason: dirtyReason)
            .disabled(when: busy, reason: busyReason)
        ]
    }

    // MARK: - Files inside a commit

    static func file(_ file: GitChangedFile, model: AppModel) -> [GitBudAction] {
        let dirty = !model.worktreeFiles.isEmpty
        let dirtyReason = "Commit or stash your changes first"

        return [
            GitBudAction(
                id: "file.copyPath",
                title: "Copy Path",
                icon: "doc.on.doc",
                perform: { _ in gitBudCopyToPasteboard(file.path) }
            ),
            GitBudAction(
                id: "file.restore",
                title: "Restore This Version",
                icon: "arrow.uturn.backward",
                interaction: .confirm(
                    title: "Restore \(file.path)?",
                    message: "The file in your working tree is replaced with this commit's version.",
                    verb: "Restore"
                ),
                perform: { _ in
                    model.selectFile(file)
                    model.restoreSelectedFileFromSelectedCommit()
                }
            ),
            GitBudAction(
                id: "file.delete",
                title: "Delete from Branch",
                icon: "trash",
                isDestructive: true,
                interaction: .confirm(
                    title: "Delete \(file.path)?",
                    message: "The file is removed and the deletion is committed. Earlier history keeps it.",
                    verb: "Delete"
                ),
                perform: { _ in
                    model.selectFile(file)
                    model.deleteSelectedFile()
                }
            )
            .disabled(when: dirty, reason: dirtyReason),
            GitBudAction(
                id: "file.purge",
                title: "Remove from All History…",
                icon: "flame",
                isDestructive: true,
                interaction: .confirmTyped(
                    title: "Purge \(file.path) from all history?",
                    message: model.purgePreview.map {
                        "This rewrites \($0.affectedCommitCount) commits on this branch. Everyone else must re-clone or reset. A backup ref is created first."
                    } ?? "Loading what this would affect…",
                    phrase: model.purgeConfirmationPhrase,
                    verb: "Purge"
                ),
                perform: { typed in
                    model.selectFile(file)
                    model.purgeConfirmationText = typed
                    model.purgeSelectedFileFromHistory()
                }
            )
            .disabled(when: !model.isPurgePreviewReady, reason: "Select the file to load a purge preview first")
            .disabled(when: dirty, reason: dirtyReason)
        ]
    }

    // MARK: - Repository-wide

    static func repository(_ model: AppModel) -> [GitBudAction] {
        let dirty = !model.worktreeFiles.isEmpty

        return [
            GitBudAction(
                id: "repo.fetch",
                title: "Fetch",
                icon: "arrow.clockwise",
                perform: { _ in model.fetchRemote() }
            )
            .disabled(when: model.isSyncingRemote, reason: "Already syncing"),
            GitBudAction(
                id: "repo.pull",
                title: "Pull with Rebase",
                icon: "arrow.down.circle",
                perform: { _ in model.pullCurrentBranchWithRebase() }
            )
            .disabled(when: dirty, reason: "Commit or stash your changes first")
            .disabled(when: model.isSyncingRemote, reason: "Already syncing"),
            GitBudAction(
                id: "repo.push",
                title: "Push",
                icon: "arrow.up.circle",
                perform: { _ in model.pushCurrentBranch() }
            )
            .disabled(when: model.isSyncingRemote, reason: "Already syncing"),
            GitBudAction(
                id: "repo.forcePush",
                title: "Push Rewritten History…",
                icon: "exclamationmark.arrow.triangle.2.circlepath",
                isDestructive: true,
                interaction: .confirmTyped(
                    title: "Force-push \(model.branchSummary?.currentBranch ?? "this branch")?",
                    message: "The remote branch is replaced with your rewritten history, using --force-with-lease. Anyone who pulled the old history must reset.",
                    phrase: model.forcePushConfirmationPhrase,
                    verb: "Force Push"
                ),
                perform: { typed in
                    model.forcePushConfirmationText = typed
                    model.pushRewrittenBranchWithLease()
                }
            )
            .disabled(when: !model.canForcePush, reason: "Nothing rewritten to publish")
            .disabled(when: model.isCurrentBranchProtected, reason: "This branch is protected — open a PR instead"),
            GitBudAction(
                id: "repo.undoRewrite",
                title: "Undo Last Rewrite",
                icon: "arrow.uturn.backward",
                perform: { _ in model.undoLastRewrite() }
            )
            .disabled(when: model.rewriteUndo == nil, reason: "No rewrite to undo")
            .disabled(when: dirty, reason: "Commit or stash your changes first"),
            GitBudAction(
                id: "repo.stash",
                title: "Stash All Changes",
                icon: "tray.and.arrow.down",
                perform: { _ in model.saveStash() }
            )
            .disabled(when: !dirty, reason: "Nothing to stash"),
            GitBudAction(
                id: "repo.draftPR",
                title: "Create Draft Pull Request",
                icon: "arrow.triangle.pull",
                perform: { _ in model.createDraftPullRequest() }
            )
            .disabled(when: model.selectedProviderRepository == nil, reason: "Connect a provider repository first")
        ]
    }

    /// Everything applicable right now, for the ⌘K palette.
    static func all(for model: AppModel) -> [GitBudAction] {
        var actions = repository(model)
        if let commit = model.focusedCommit {
            actions += self.commit(commit, model: model)
        }
        if let branch = model.branches.first(where: \.isCurrent) {
            actions += self.branch(branch, model: model).filter { $0.id != "branch.checkout" }
        }
        return actions
    }
}
