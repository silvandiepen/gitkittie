import XCTest
@testable import GitKit

#if os(macOS)
final class GitHistoryTests: XCTestCase {
    private let runner = GitProcessRunner()
    private let history = ShellGitHistoryService()
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gitbud-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testProtectedBranchPolicyMatchesExactAndWildcardBranches() {
        let policy = GitProtectedBranchPolicy(patterns: ["main", "release/*"])

        XCTAssertTrue(policy.protects("main"))
        XCTAssertTrue(policy.protects("release/1.0"))
        XCTAssertFalse(policy.protects("feature/rewrite"))
        XCTAssertFalse(policy.protects(nil))
    }

    private func makeRepo(_ name: String = "repo") throws -> URL {
        let repo = tmp.appendingPathComponent(name)
        try require(["init", repo.path], in: tmp)
        try require(["config", "user.email", "gitbud@example.com"], in: repo)
        try require(["config", "user.name", "GitBud Test"], in: repo)
        return repo
    }

    private func write(_ text: String, to repo: URL, _ path: String) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func commit(_ message: String, repo: URL) throws {
        try require(["add", "-A"], in: repo)
        try require(["commit", "-m", message], in: repo)
    }

    func testCommitGraphChangedFilesDiffAndSafetyBranchUseRealGit() async throws {
        let repo = try makeRepo()
        try write("one\n", to: repo, "Sources/App.swift")
        try commit("feat: seed app", repo: repo)
        try write("one\ntwo\n", to: repo, "Sources/App.swift")
        try write("notes\n", to: repo, "README.md")
        try commit("feat: expand app", repo: repo)

        let graph = try await history.commitGraph(at: repo)
        XCTAssertEqual(graph.first?.subject, "feat: expand app")
        XCTAssertEqual(graph.first?.parentIDs.count, 1)
        XCTAssertTrue(graph.first?.author == "GitBud Test")

        let files = try await history.changedFiles(at: repo, commit: "HEAD")
        XCTAssertTrue(files.contains { $0.path == "Sources/App.swift" && $0.status == "M" })
        XCTAssertTrue(files.contains { $0.path == "README.md" && $0.status == "A" })

        let diff = try await history.diff(at: repo, commit: "HEAD")
        XCTAssertTrue(diff.contains { $0.path == "Sources/App.swift" && $0.hunks.contains { $0.lines.contains("+two") } })

        let safety = try await history.createSafetyBranch(at: repo)
        let branches = try require(["branch", "--list", safety], in: repo).standardOutput
        XCTAssertTrue(branches.contains(safety))
    }

    func testSearchCommitsFindsMessagesAndChangedTextWithRealGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "story.txt")
        try commit("seed story", repo: repo)
        try write("base\nneedle\n", to: repo, "story.txt")
        try require(["add", "-A"], in: repo)
        try require(["commit", "-m", "feat: parser cleanup", "-m", "Body mentions searchable context."], in: repo)
        let parserCommit = try revParse("HEAD", repo: repo)
        try write("notes\n", to: repo, "notes.txt")
        try commit("docs: notes", repo: repo)

        let messageMatches = try await history.searchCommits(at: repo, query: "PARSER", mode: .message)
        let changeMatches = try await history.searchCommits(at: repo, query: "needle", mode: .changes)

        XCTAssertEqual(messageMatches.map(\.id), [parserCommit])
        XCTAssertEqual(changeMatches.map(\.id), [parserCommit])
        XCTAssertEqual(messageMatches.first?.subject, "feat: parser cleanup")
        XCTAssertEqual(messageMatches.first?.body, "Body mentions searchable context.")
    }

    func testBranchesCreateAndCheckoutUseRealGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let initialBranch = try require(["branch", "--show-current"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = try revParse("HEAD", repo: repo)
        try write("main\n", to: repo, "main.txt")
        try commit("main work", repo: repo)

        try await history.createBranch(at: repo, name: "feature/from-base", startPoint: base, checkout: true)
        var branches = try await history.branches(at: repo)
        XCTAssertEqual(branches.first { $0.shortName == "feature/from-base" }?.isCurrent, true)
        XCTAssertEqual(try require(["branch", "--show-current"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "feature/from-base")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("main.txt").path))

        try write("feature\n", to: repo, "feature.txt")
        try commit("feature work", repo: repo)
        try await history.checkoutBranch(at: repo, name: initialBranch)
        branches = try await history.branches(at: repo)
        XCTAssertEqual(branches.first { $0.shortName == initialBranch }?.isCurrent, true)
        XCTAssertEqual(try read(repo, "main.txt"), "main\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("feature.txt").path))
    }

    func testBranchesRenameAndDeleteUseRealGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let initialBranch = try require(["branch", "--show-current"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        try await history.createBranch(at: repo, name: "feature/old", startPoint: "HEAD", checkout: false)

        try await history.renameBranch(at: repo, oldName: "feature/old", newName: "feature/new")
        var branches = try await history.branches(at: repo)
        XCTAssertFalse(branches.contains { $0.shortName == "feature/old" })
        XCTAssertTrue(branches.contains { $0.shortName == "feature/new" })

        try await history.deleteBranch(at: repo, name: "feature/new")
        branches = try await history.branches(at: repo)
        XCTAssertFalse(branches.contains { $0.shortName == "feature/new" })
        XCTAssertEqual(try require(["branch", "--show-current"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), initialBranch)
    }

    func testCheckoutRemoteBranchCreatesLocalTrackingBranch() async throws {
        let remote = tmp.appendingPathComponent("tracking-remote.git")
        try require(["init", "--bare", remote.path], in: tmp)
        let source = tmp.appendingPathComponent("tracking-source")
        let repo = tmp.appendingPathComponent("tracking-repo")
        try require(["clone", remote.path, source.path], in: tmp)
        try require(["config", "user.email", "source@example.com"], in: source)
        try require(["config", "user.name", "Source"], in: source)
        try write("base\n", to: source, "base.txt")
        try commit("base", repo: source)
        try require(["push", "-u", "origin", "HEAD"], in: source)
        try require(["switch", "-c", "feature/tracking"], in: source)
        try write("feature\n", to: source, "feature.txt")
        try commit("feature tracking", repo: source)
        try require(["push", "-u", "origin", "HEAD"], in: source)
        try require(["clone", remote.path, repo.path], in: tmp)
        try require(["config", "user.email", "repo@example.com"], in: repo)
        try require(["config", "user.name", "Repo"], in: repo)

        let branches = try await history.branches(at: repo)
        XCTAssertTrue(branches.contains { $0.shortName == "origin/feature/tracking" && $0.kind == .remote })

        try await history.checkoutRemoteBranch(at: repo, remoteName: "origin/feature/tracking")

        XCTAssertEqual(try require(["branch", "--show-current"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "feature/tracking")
        XCTAssertEqual(try require(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "origin/feature/tracking")
        XCTAssertEqual(try read(repo, "feature.txt"), "feature\n")
    }

    func testTagsCreateListAndDeleteUseRealGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let base = try revParse("HEAD", repo: repo)
        try write("later\n", to: repo, "later.txt")
        try commit("later", repo: repo)

        try await history.createTag(at: repo, name: "v1.0.0", target: base)
        var tags = try await history.tags(at: repo)
        let tag = try XCTUnwrap(tags.first { $0.name == "v1.0.0" })
        XCTAssertEqual(tag.commitID, base)
        XCTAssertEqual(tag.subject, "base")

        try await history.deleteTag(at: repo, name: "v1.0.0")
        tags = try await history.tags(at: repo)
        XCTAssertFalse(tags.contains { $0.name == "v1.0.0" })
    }

    func testRemotesAddListAndRemoveUseRealGit() async throws {
        let repo = try makeRepo()
        let remote = tmp.appendingPathComponent("remote-management.git")
        try require(["init", "--bare", remote.path], in: tmp)

        try await history.addRemote(at: repo, name: "origin", url: remote.path)
        var remotes = try await history.remotes(at: repo)
        let origin = try XCTUnwrap(remotes.first { $0.name == "origin" })
        XCTAssertEqual(origin.fetchURL, remote.path)
        XCTAssertEqual(origin.pushURL, remote.path)
        XCTAssertEqual(
            try require(["remote", "get-url", "origin"], in: repo).standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines),
            remote.path
        )

        try await history.removeRemote(at: repo, name: "origin")
        remotes = try await history.remotes(at: repo)
        XCTAssertFalse(remotes.contains { $0.name == "origin" })
        XCTAssertFalse(try runner.run(["remote", "get-url", "origin"], in: repo).succeeded)
    }

    func testBranchFlowExplainsCurrentAndTargetCommitsFromMergeBase() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let initialBranch = try require(["branch", "--show-current"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        try await history.createBranch(at: repo, name: "feature/flow", startPoint: "HEAD", checkout: true)
        try write("feature 1\n", to: repo, "feature-one.txt")
        try commit("feature one", repo: repo)
        try write("feature 2\n", to: repo, "feature-two.txt")
        try commit("feature two", repo: repo)
        try await history.checkoutBranch(at: repo, name: initialBranch)
        try write("main 1\n", to: repo, "main-one.txt")
        try commit("main one", repo: repo)

        let flow = try await history.branchFlow(at: repo, targetBranch: "feature/flow")

        XCTAssertEqual(flow.currentBranch, initialBranch)
        XCTAssertEqual(flow.targetBranch, "feature/flow")
        XCTAssertEqual(flow.mergeBaseSubject, "base")
        XCTAssertEqual(flow.currentOnlyCommits.map(\.subject), ["main one"])
        XCTAssertEqual(flow.targetOnlyCommits.map(\.subject), ["feature one", "feature two"])
        XCTAssertEqual(flow.currentAheadCount, 1)
        XCTAssertEqual(flow.targetAheadCount, 2)
        XCTAssertEqual(flow.changedFiles.map(\.path).sorted(), ["feature-one.txt", "feature-two.txt", "main-one.txt"])
        XCTAssertTrue(flow.changedFiles.contains { $0.path == "feature-one.txt" && $0.status == "A" })
        XCTAssertTrue(flow.changedFiles.contains { $0.path == "feature-two.txt" && $0.status == "A" })
        XCTAssertTrue(flow.changedFiles.contains { $0.path == "main-one.txt" && $0.status == "D" })
    }

    func testMergeBranchLandsOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let initialBranch = try require(["branch", "--show-current"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        try await history.createBranch(at: repo, name: "feature/merge", startPoint: "HEAD", checkout: true)
        try write("feature\n", to: repo, "feature.txt")
        try commit("feature work", repo: repo)
        try await history.checkoutBranch(at: repo, name: initialBranch)
        try write("main\n", to: repo, "main.txt")
        try commit("main work", repo: repo)

        let result = try await history.mergeBranch(at: repo, name: "feature/merge")

        XCTAssertTrue(result.completed)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(try read(repo, "feature.txt"), "feature\n")
        XCTAssertEqual(try read(repo, "main.txt"), "main\n")
        XCTAssertEqual(try logSubjects(repo).first, "Merge branch 'feature/merge'")
    }

    func testRebaseCurrentBranchOntoBranchSurfacesConflictsAndCanResolve() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "story.txt")
        try commit("base", repo: repo)
        let initialBranch = try require(["branch", "--show-current"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        try await history.createBranch(at: repo, name: "feature/rebase-conflict", startPoint: "HEAD", checkout: true)
        try write("your version\n", to: repo, "story.txt")
        try commit("feature edit", repo: repo)
        try await history.checkoutBranch(at: repo, name: initialBranch)
        try write("remote version\n", to: repo, "story.txt")
        try commit("main edit", repo: repo)
        try await history.checkoutBranch(at: repo, name: "feature/rebase-conflict")

        let result = try await history.rebaseCurrentBranch(onto: initialBranch, at: repo)

        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.conflicts.map(\.path), ["story.txt"])
        XCTAssertEqual(result.conflicts.first?.sections.map(\.side.rawValue), ["Your change", "REmote change"])

        try await history.resolveConflict(at: repo, path: "story.txt", taking: .yourChange, mode: .rebase)
        try await history.continueRebase(at: repo)

        XCTAssertEqual(try read(repo, "story.txt"), "your version\n")
        XCTAssertEqual(try require(["branch", "--show-current"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "feature/rebase-conflict")
    }

    func testWorktreeFilesStageUnstageAndDiscardUseRealGit() async throws {
        let repo = try makeRepo()
        try write("one\n", to: repo, "story.txt")
        try commit("seed", repo: repo)
        try write("two\n", to: repo, "story.txt")

        var files = try await history.worktreeFiles(at: repo)
        XCTAssertEqual(files.map(\.path), ["story.txt"])
        XCTAssertEqual(files.first?.indexStatus, " ")
        XCTAssertEqual(files.first?.workingTreeStatus, "M")

        try await history.stagePaths(at: repo, paths: ["story.txt"])
        files = try await history.worktreeFiles(at: repo)
        XCTAssertEqual(files.first?.indexStatus, "M")
        XCTAssertEqual(files.first?.workingTreeStatus, " ")
        let staged = try require(["diff", "--cached", "--name-only"], in: repo).standardOutput
        XCTAssertEqual(staged.trimmingCharacters(in: .whitespacesAndNewlines), "story.txt")

        try await history.unstagePaths(at: repo, paths: ["story.txt"])
        files = try await history.worktreeFiles(at: repo)
        XCTAssertEqual(files.first?.indexStatus, " ")
        XCTAssertEqual(files.first?.workingTreeStatus, "M")
        XCTAssertTrue(try require(["diff", "--cached", "--quiet"], in: repo).succeeded)

        try await history.discardPaths(at: repo, paths: ["story.txt"])
        files = try await history.worktreeFiles(at: repo)
        XCTAssertTrue(files.isEmpty)
        XCTAssertEqual(try read(repo, "story.txt"), "one\n")
    }

    func testLinkedWorktreesAddListAndRemoveUseRealGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let linkedPath = tmp.appendingPathComponent("linked-feature").path
        let normalizedRepoPath = repo.standardizedFileURL.path
        let normalizedLinkedPath = URL(fileURLWithPath: linkedPath).standardizedFileURL.path

        try await history.addLinkedWorktree(at: repo, path: linkedPath, branchName: "feature/worktree")
        let withLinked = try await history.linkedWorktrees(at: repo)

        XCTAssertTrue(withLinked.contains { $0.path == normalizedRepoPath && $0.isCurrent })
        let linked = try XCTUnwrap(withLinked.first { $0.path == normalizedLinkedPath })
        XCTAssertEqual(linked.branch, "feature/worktree")
        XCTAssertFalse(linked.isCurrent)
        XCTAssertEqual(try read(URL(fileURLWithPath: linkedPath), "base.txt"), "base\n")

        try await history.removeLinkedWorktree(at: repo, path: linkedPath)
        let afterRemove = try await history.linkedWorktrees(at: repo)

        XCTAssertFalse(afterRemove.contains { $0.path == normalizedLinkedPath })
        XCTAssertFalse(FileManager.default.fileExists(atPath: linkedPath))
    }

    func testSubmodulesListAndUpdateUseRealGit() async throws {
        let submoduleRepo = try makeRepo("submodule-source")
        try write("submodule\n", to: submoduleRepo, "module.txt")
        try commit("submodule seed", repo: submoduleRepo)
        let submoduleCommit = try revParse("HEAD", repo: submoduleRepo)

        let repo = try makeRepo("super")
        try require(["-c", "protocol.file.allow=always", "submodule", "add", submoduleRepo.path, "Vendor/Sub"], in: repo)
        try commit("add submodule", repo: repo)

        var submodules = try await history.submodules(at: repo)
        let initialized = try XCTUnwrap(submodules.first)
        XCTAssertEqual(initialized.path, "Vendor/Sub")
        XCTAssertEqual(initialized.commitID, submoduleCommit)
        XCTAssertEqual(initialized.state, .initialized)

        try require(["submodule", "deinit", "-f", "Vendor/Sub"], in: repo)
        submodules = try await history.submodules(at: repo)
        XCTAssertEqual(submodules.first?.state, .uninitialized)

        try await history.updateSubmodules(at: repo, paths: ["Vendor/Sub"])

        submodules = try await history.submodules(at: repo)
        XCTAssertEqual(submodules.first?.state, .initialized)
        XCTAssertEqual(try read(repo.appendingPathComponent("Vendor/Sub"), "module.txt"), "submodule\n")
    }

    func testRestorePathsFromCommitWritesSelectedVersionToWorktree() async throws {
        let repo = try makeRepo()
        try write("old\n", to: repo, "story.txt")
        try commit("seed", repo: repo)
        let oldCommit = try revParse("HEAD", repo: repo)
        try write("new\n", to: repo, "story.txt")
        try commit("update", repo: repo)

        try await history.restorePaths(at: repo, paths: ["story.txt"], from: oldCommit)

        XCTAssertEqual(try read(repo, "story.txt"), "old\n")
        XCTAssertEqual(try require(["show", "HEAD:story.txt"], in: repo).standardOutput, "new\n")
        let files = try await history.worktreeFiles(at: repo)
        XCTAssertTrue(files.contains { $0.path == "story.txt" && $0.workingTreeStatus == "M" })
    }

    func testAmendHeadWithSelectedPathsOnlyLandsOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "selected.txt")
        try write("keep\n", to: repo, "left-alone.txt")
        try commit("feat: seed", repo: repo)

        try write("base\nselected amend\n", to: repo, "selected.txt")
        try write("new file\n", to: repo, "new.txt")
        try write("keep\nunselected\n", to: repo, "left-alone.txt")

        try await history.amendHeadWithPaths(at: repo, paths: ["selected.txt", "new.txt"])

        XCTAssertEqual(try logSubjects(repo).first, "feat: seed")
        let committedFiles = try require(["show", "--format=", "--name-only", "HEAD"], in: repo).standardOutput
            .split(separator: "\n")
            .map(String.init)
        XCTAssertTrue(committedFiles.contains("selected.txt"))
        XCTAssertTrue(committedFiles.contains("new.txt"))
        XCTAssertTrue(committedFiles.contains("left-alone.txt"))
        XCTAssertEqual(try require(["show", "HEAD:selected.txt"], in: repo).standardOutput, "base\nselected amend\n")
        XCTAssertEqual(try require(["show", "HEAD:new.txt"], in: repo).standardOutput, "new file\n")
        XCTAssertEqual(try require(["show", "HEAD:left-alone.txt"], in: repo).standardOutput, "keep\n")
        XCTAssertTrue(try require(["status", "--porcelain", "--", "left-alone.txt"], in: repo).standardOutput.contains(" M left-alone.txt"))
    }

    func testStashSaveApplyAndDropUseRealGit() async throws {
        let repo = try makeRepo()
        try write("one\n", to: repo, "story.txt")
        try commit("seed", repo: repo)
        try write("two\n", to: repo, "story.txt")
        try write("scratch\n", to: repo, "scratch.txt")

        try await history.saveStash(at: repo, message: "WIP story")
        var files = try await history.worktreeFiles(at: repo)
        XCTAssertTrue(files.isEmpty)
        var stashes = try await history.stashes(at: repo)
        let stash = try XCTUnwrap(stashes.first)
        XCTAssertEqual(stash.id, "stash@{0}")
        XCTAssertEqual(stash.message, "WIP story")
        XCTAssertEqual(try read(repo, "story.txt"), "one\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("scratch.txt").path))

        try await history.applyStash(at: repo, id: stash.id)
        files = try await history.worktreeFiles(at: repo)
        XCTAssertTrue(files.contains { $0.path == "story.txt" && $0.workingTreeStatus == "M" })
        XCTAssertTrue(files.contains { $0.path == "scratch.txt" && $0.displayStatus == "?" })
        XCTAssertEqual(try read(repo, "story.txt"), "two\n")
        XCTAssertEqual(try read(repo, "scratch.txt"), "scratch\n")

        try await history.dropStash(at: repo, id: stash.id)
        stashes = try await history.stashes(at: repo)
        XCTAssertTrue(stashes.isEmpty)
    }

    func testSaveStashWithSelectedPathsLeavesUnselectedChangesInWorktree() async throws {
        let repo = try makeRepo()
        try write("one\n", to: repo, "selected.txt")
        try write("keep\n", to: repo, "left-alone.txt")
        try commit("seed", repo: repo)
        try write("two\n", to: repo, "selected.txt")
        try write("changed\n", to: repo, "left-alone.txt")
        try write("scratch\n", to: repo, "scratch.txt")
        try write("unselected\n", to: repo, "unselected.txt")

        try await history.saveStash(at: repo, message: "selected WIP", paths: ["selected.txt", "scratch.txt"])

        XCTAssertEqual(try read(repo, "selected.txt"), "one\n")
        XCTAssertEqual(try read(repo, "left-alone.txt"), "changed\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("scratch.txt").path))
        XCTAssertEqual(try read(repo, "unselected.txt"), "unselected\n")

        let files = try await history.worktreeFiles(at: repo)
        XCTAssertTrue(files.contains { $0.path == "left-alone.txt" && $0.workingTreeStatus == "M" })
        XCTAssertTrue(files.contains { $0.path == "unselected.txt" && $0.displayStatus == "?" })
        XCTAssertFalse(files.contains { $0.path == "selected.txt" })
        XCTAssertFalse(files.contains { $0.path == "scratch.txt" })

        let stashes = try await history.stashes(at: repo)
        let stash = try XCTUnwrap(stashes.first)
        XCTAssertEqual(stash.message, "selected WIP")
    }

    func testPopStashAppliesAndDropsStashOnGit() async throws {
        let repo = try makeRepo()
        try write("one\n", to: repo, "story.txt")
        try commit("seed", repo: repo)
        try write("two\n", to: repo, "story.txt")
        try await history.saveStash(at: repo, message: "pop me")
        var stashes = try await history.stashes(at: repo)
        let stash = try XCTUnwrap(stashes.first)

        let result = try await history.popStash(at: repo, id: stash.id)

        XCTAssertTrue(result.completed)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(try read(repo, "story.txt"), "two\n")
        stashes = try await history.stashes(at: repo)
        XCTAssertTrue(stashes.isEmpty)
        let files = try await history.worktreeFiles(at: repo)
        XCTAssertTrue(files.contains { $0.path == "story.txt" && $0.workingTreeStatus == "M" })
    }

    func testPopStashSurfacesConflictsAndFinishDropsStashAfterResolution() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "story.txt")
        try commit("seed", repo: repo)
        try write("stashed\n", to: repo, "story.txt")
        try await history.saveStash(at: repo, message: "conflicting stash")
        var stashes = try await history.stashes(at: repo)
        let stash = try XCTUnwrap(stashes.first)
        try write("current\n", to: repo, "story.txt")
        try commit("current", repo: repo)

        let result = try await history.popStash(at: repo, id: stash.id)

        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.conflicts.first?.path, "story.txt")
        XCTAssertEqual(result.conflicts.first?.sections.map(\.side.rawValue), ["Your change", "REmote change"])
        stashes = try await history.stashes(at: repo)
        XCTAssertEqual(stashes.first?.id, stash.id)

        try await history.resolveConflict(at: repo, path: "story.txt", taking: .remoteChange, mode: .stashPop)
        try await history.finishStashPop(at: repo, id: stash.id)

        XCTAssertEqual(try read(repo, "story.txt"), "stashed\n")
        stashes = try await history.stashes(at: repo)
        XCTAssertTrue(stashes.isEmpty)
    }

    func testCreateBranchFromStashSwitchesBranchAppliesAndDropsStash() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "story.txt")
        try commit("seed", repo: repo)
        try write("stashed\n", to: repo, "story.txt")
        try await history.saveStash(at: repo, message: "branch me")
        var stashes = try await history.stashes(at: repo)
        let stash = try XCTUnwrap(stashes.first)

        try await history.createBranchFromStash(at: repo, id: stash.id, branchName: "feature/stash-work")

        XCTAssertEqual(try require(["branch", "--show-current"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "feature/stash-work")
        XCTAssertEqual(try read(repo, "story.txt"), "stashed\n")
        stashes = try await history.stashes(at: repo)
        XCTAssertTrue(stashes.isEmpty)
        let files = try await history.worktreeFiles(at: repo)
        XCTAssertTrue(files.contains { $0.path == "story.txt" && $0.workingTreeStatus == "M" })
    }

    func testConflictSectionsUseYourChangeAndREmoteChangeLabels() throws {
        let text = """
        keep
        <<<<<<< HEAD
        local line
        =======
        incoming line
        >>>>>>> origin/main
        done
        """

        let sections = ShellGitHistoryService.parseConflictSections(text)
        XCTAssertEqual(sections.map(\.side), [.yourChange, .remoteChange])
        XCTAssertEqual(sections[0].side.rawValue, "Your change")
        XCTAssertEqual(sections[1].side.rawValue, "REmote change")
        XCTAssertEqual(sections[0].lines, ["local line"])
        XCTAssertEqual(sections[1].lines, ["incoming line"])
    }

    func testBlamePorcelainParserKeepsLineMetadata() {
        let text = """
        abcdef1234567890 1 1 1
        author Ada
        summary seed line
        \tone
        fedcba9876543210 2 2 1
        author Grace
        summary update line
        \ttwo
        """

        let lines = ShellGitHistoryService.parseBlamePorcelain(text)

        XCTAssertEqual(lines.map(\.lineNumber), [1, 2])
        XCTAssertEqual(lines.map(\.shortCommitID), ["abcdef12", "fedcba98"])
        XCTAssertEqual(lines.map(\.author), ["Ada", "Grace"])
        XCTAssertEqual(lines.map(\.summary), ["seed line", "update line"])
        XCTAssertEqual(lines.map(\.content), ["one", "two"])
    }

    func testBlameUsesRealGitLineHistory() async throws {
        let repo = try makeRepo()
        try write("one\ntwo\n", to: repo, "story.txt")
        try commit("seed story", repo: repo)
        try write("one\nTWO\n", to: repo, "story.txt")
        try commit("update second line", repo: repo)

        let blame = try await history.blame(at: repo, path: "story.txt")

        XCTAssertEqual(blame.map(\.lineNumber), [1, 2])
        XCTAssertEqual(blame.map(\.content), ["one", "TWO"])
        XCTAssertEqual(blame[0].summary, "seed story")
        XCTAssertEqual(blame[1].summary, "update second line")
        XCTAssertEqual(blame[0].author, "GitBud Test")
    }

    func testConflictDiscoveryReadsUnmergedFiles() async throws {
        let remote = tmp.appendingPathComponent("remote.git")
        try require(["init", "--bare", remote.path], in: tmp)

        let a = tmp.appendingPathComponent("a")
        let b = tmp.appendingPathComponent("b")
        try require(["clone", remote.path, a.path], in: tmp)
        try require(["clone", remote.path, b.path], in: tmp)
        try require(["config", "user.email", "a@example.com"], in: a)
        try require(["config", "user.name", "A"], in: a)
        try require(["config", "user.email", "b@example.com"], in: b)
        try require(["config", "user.name", "B"], in: b)

        try write("base\n", to: a, "story.txt")
        try commit("seed", repo: a)
        try require(["push", "-u", "origin", "HEAD"], in: a)
        try require(["pull"], in: b)

        try write("your version\n", to: b, "story.txt")
        try commit("local edit", repo: b)

        try write("remote version\n", to: a, "story.txt")
        try commit("remote edit", repo: a)
        try require(["push"], in: a)

        _ = try runner.run(["pull", "--rebase"], in: b)
        let conflicts = try await history.conflicts(at: b)
        XCTAssertEqual(conflicts.map(\.path), ["story.txt"])
        XCTAssertEqual(conflicts[0].sections.map(\.side.rawValue), ["Your change", "REmote change"])
    }

    func testSquashRecentCommitsLandsAsSingleCommitWithCombinedTree() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try write("one\n", to: repo, "one.txt")
        try commit("one", repo: repo)
        try write("two\n", to: repo, "two.txt")
        try commit("two", repo: repo)

        try await history.squashRecentCommits(at: repo, count: 2, message: "combined")

        XCTAssertEqual(try logSubjects(repo), ["combined", "base"])
        XCTAssertEqual(try read(repo, "one.txt"), "one\n")
        XCTAssertEqual(try read(repo, "two.txt"), "two\n")
    }

    func testSplitHeadCommitByFilesCreatesSelectedAndRemainingCommits() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try write("selected\n", to: repo, "selected.txt")
        try write("remaining\n", to: repo, "remaining.txt")
        try commit("mixed", repo: repo)

        try await history.splitHeadCommitByFiles(
            at: repo,
            paths: ["selected.txt"],
            newCommitMessage: "selected only",
            remainingCommitMessage: "remaining only"
        )

        XCTAssertEqual(try logSubjects(repo), ["remaining only", "selected only", "base"])
        let selectedFiles = try require(["show", "--format=", "--name-only", "HEAD~1"], in: repo).standardOutput
        let remainingFiles = try require(["show", "--format=", "--name-only", "HEAD"], in: repo).standardOutput
        XCTAssertTrue(selectedFiles.contains("selected.txt"))
        XCTAssertFalse(selectedFiles.contains("remaining.txt"))
        XCTAssertTrue(remainingFiles.contains("remaining.txt"))
        XCTAssertFalse(remainingFiles.contains("selected.txt"))
    }

    func testSplitNonHeadCommitByFilesPreservesLaterCommits() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try write("selected\n", to: repo, "selected.txt")
        try write("remaining\n", to: repo, "remaining.txt")
        try commit("mixed", repo: repo)
        let mixed = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try write("later\n", to: repo, "later.txt")
        try commit("later work", repo: repo)

        try await history.splitCommitByFiles(
            at: repo,
            commit: mixed,
            paths: ["selected.txt"],
            newCommitMessage: "selected only",
            remainingCommitMessage: "remaining only"
        )

        XCTAssertEqual(try logSubjects(repo), ["later work", "remaining only", "selected only", "base"])
        XCTAssertEqual(try read(repo, "selected.txt"), "selected\n")
        XCTAssertEqual(try read(repo, "remaining.txt"), "remaining\n")
        XCTAssertEqual(try read(repo, "later.txt"), "later\n")
        let selectedFiles = try require(["show", "--format=", "--name-only", "HEAD~2"], in: repo).standardOutput
        let remainingFiles = try require(["show", "--format=", "--name-only", "HEAD~1"], in: repo).standardOutput
        XCTAssertTrue(selectedFiles.contains("selected.txt"))
        XCTAssertFalse(selectedFiles.contains("remaining.txt"))
        XCTAssertTrue(remainingFiles.contains("remaining.txt"))
        XCTAssertFalse(remainingFiles.contains("selected.txt"))
    }

    func testSplitHeadCommitByHunksCreatesSelectedAndRemainingCommits() async throws {
        let repo = try makeRepo()
        try write(
            """
            one
            two
            three
            four
            five
            six
            seven
            eight
            nine
            ten
            eleven
            twelve
            """,
            to: repo,
            "story.txt"
        )
        try commit("base", repo: repo)
        try write(
            """
            ONE
            two
            three
            four
            five
            six
            seven
            eight
            nine
            ten
            ELEVEN
            twelve
            """,
            to: repo,
            "story.txt"
        )
        try commit("mixed hunks", repo: repo)

        let diff = try await history.diff(at: repo, commit: "HEAD")
        let hunkIDs = diff.flatMap(\.hunks).map(\.id)
        XCTAssertEqual(hunkIDs, ["story.txt:0", "story.txt:1"])

        try await history.splitHeadCommitByHunks(
            at: repo,
            hunkIDs: ["story.txt:0"],
            newCommitMessage: "first hunk",
            remainingCommitMessage: "second hunk"
        )

        XCTAssertEqual(try logSubjects(repo), ["second hunk", "first hunk", "base"])
        let selectedPatch = try require(["show", "--format=", "HEAD~1"], in: repo).standardOutput
        let remainingPatch = try require(["show", "--format=", "HEAD"], in: repo).standardOutput
        XCTAssertTrue(selectedPatch.contains("+ONE"))
        XCTAssertFalse(selectedPatch.contains("+ELEVEN"))
        XCTAssertTrue(remainingPatch.contains("+ELEVEN"))
        XCTAssertFalse(remainingPatch.contains("+ONE"))
        XCTAssertEqual(try read(repo, "story.txt").contains("ONE"), true)
        XCTAssertEqual(try read(repo, "story.txt").contains("ELEVEN"), true)
    }

    func testSplitNonHeadCommitByHunksPreservesLaterCommits() async throws {
        let repo = try makeRepo()
        try write(
            """
            one
            two
            three
            four
            five
            six
            seven
            eight
            nine
            ten
            eleven
            twelve
            """,
            to: repo,
            "story.txt"
        )
        try commit("base", repo: repo)
        try write(
            """
            ONE
            two
            three
            four
            five
            six
            seven
            eight
            nine
            ten
            ELEVEN
            twelve
            """,
            to: repo,
            "story.txt"
        )
        try commit("mixed hunks", repo: repo)
        let mixed = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try write("later\n", to: repo, "later.txt")
        try commit("later work", repo: repo)

        try await history.splitCommitByHunks(
            at: repo,
            commit: mixed,
            hunkIDs: ["story.txt:0"],
            newCommitMessage: "first hunk",
            remainingCommitMessage: "second hunk"
        )

        XCTAssertEqual(try logSubjects(repo), ["later work", "second hunk", "first hunk", "base"])
        let selectedPatch = try require(["show", "--format=", "HEAD~2"], in: repo).standardOutput
        let remainingPatch = try require(["show", "--format=", "HEAD~1"], in: repo).standardOutput
        XCTAssertTrue(selectedPatch.contains("+ONE"))
        XCTAssertFalse(selectedPatch.contains("+ELEVEN"))
        XCTAssertTrue(remainingPatch.contains("+ELEVEN"))
        XCTAssertFalse(remainingPatch.contains("+ONE"))
        XCTAssertEqual(try read(repo, "story.txt").contains("ONE"), true)
        XCTAssertEqual(try read(repo, "story.txt").contains("ELEVEN"), true)
        XCTAssertEqual(try read(repo, "later.txt"), "later\n")
    }

    func testEditHeadCommitMessageKeepsTree() async throws {
        let repo = try makeRepo()
        try write("one\n", to: repo, "file.txt")
        try commit("rough message", repo: repo)

        try await history.editHeadCommitMessage(at: repo, message: "feat: polished message")

        XCTAssertEqual(try logSubjects(repo), ["feat: polished message"])
        XCTAssertEqual(try read(repo, "file.txt"), "one\n")
    }

    func testDeleteFileAndCommitRemovesCurrentFileOnly() async throws {
        let repo = try makeRepo()
        try write("keep\n", to: repo, "keep.txt")
        try write("delete\n", to: repo, "delete.txt")
        try commit("seed", repo: repo)

        try await history.deleteFileAndCommit(at: repo, path: "delete.txt", message: "Remove delete.txt")

        XCTAssertEqual(try logSubjects(repo), ["Remove delete.txt", "seed"])
        XCTAssertEqual(try read(repo, "keep.txt"), "keep\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("delete.txt").path))
    }

    func testPurgePathsFromCurrentBranchHistoryRemovesPathFromEveryCommit() async throws {
        let repo = try makeRepo()
        try write("public 1\n", to: repo, "public.txt")
        try write("secret 1\n", to: repo, "secret.txt")
        try commit("seed with secret", repo: repo)
        try write("public 2\n", to: repo, "public.txt")
        try write("secret 2\n", to: repo, "secret.txt")
        try commit("update secret", repo: repo)
        try write("public 3\n", to: repo, "public.txt")
        try commit("public only", repo: repo)

        let preview = try await history.purgePreview(at: repo, paths: ["secret.txt"])
        XCTAssertEqual(preview.paths, ["secret.txt"])
        XCTAssertEqual(preview.affectedCommits.map(\.subject), ["update secret", "seed with secret"])
        XCTAssertTrue(preview.affectedBranches.contains("main") || preview.affectedBranches.contains("master"))
        XCTAssertTrue(preview.affectedTags.isEmpty)
        XCTAssertNotNil(preview.repositorySizeBytes)

        let backup = try await history.purgePathsFromCurrentBranchHistory(at: repo, paths: ["secret.txt"])

        XCTAssertTrue(try require(["branch", "--list", backup], in: repo).standardOutput.contains(backup))
        XCTAssertEqual(try logSubjects(repo), ["public only", "update secret", "seed with secret"])
        XCTAssertEqual(try read(repo, "public.txt"), "public 3\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("secret.txt").path))
        let commits = try require(["rev-list", "HEAD"], in: repo).standardOutput.split(separator: "\n").map(String.init)
        for commit in commits {
            let tree = try require(["ls-tree", "-r", "--name-only", commit], in: repo).standardOutput
            XCTAssertFalse(tree.split(separator: "\n").contains("secret.txt"))
        }
    }

    func testPushForceWithLeaseUpdatesRemoteAfterRewrite() async throws {
        let remote = tmp.appendingPathComponent("push-remote.git")
        try require(["init", "--bare", remote.path], in: tmp)
        let repo = tmp.appendingPathComponent("push-repo")
        try require(["clone", remote.path, repo.path], in: tmp)
        try require(["config", "user.email", "gitbud@example.com"], in: repo)
        try require(["config", "user.name", "GitBud Test"], in: repo)
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try require(["push", "-u", "origin", "HEAD"], in: repo)
        try write("one\n", to: repo, "one.txt")
        try commit("one", repo: repo)
        try require(["push"], in: repo)

        try await history.editHeadCommitMessage(at: repo, message: "one rewritten")
        let ready = try await history.forceWithLeaseReadiness(at: repo)
        XCTAssertTrue(ready)
        try await history.pushForceWithLease(at: repo)

        let remoteSubject = try require(["log", "--format=%s", "-1", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(remoteSubject, "one rewritten")
        let remoteHead = try require(["ls-remote", "origin", "HEAD"], in: repo).standardOutput
        XCTAssertTrue(remoteHead.contains(try revParse("HEAD", repo: repo)))
    }

    func testPushCurrentBranchUpdatesExistingUpstreamRemote() async throws {
        let remote = tmp.appendingPathComponent("push-current-remote.git")
        try require(["init", "--bare", remote.path], in: tmp)
        let repo = tmp.appendingPathComponent("push-current-repo")
        try require(["clone", remote.path, repo.path], in: tmp)
        try require(["config", "user.email", "gitbud@example.com"], in: repo)
        try require(["config", "user.name", "GitBud Test"], in: repo)
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try require(["push", "-u", "origin", "HEAD"], in: repo)
        let branch = try require(["branch", "--show-current"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)

        try write("local\n", to: repo, "local.txt")
        try commit("local change", repo: repo)
        try await history.pushCurrentBranch(at: repo)

        let remoteSubject = try require(["--git-dir", remote.path, "log", "--format=%s", "-1", "refs/heads/\(branch)"], in: tmp).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(remoteSubject, "local change")
        let aheadBehind = try require(["rev-list", "--left-right", "--count", "@{u}...HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(aheadBehind, "0\t0")
    }

    func testPushCurrentBranchSetsUpstreamWhenMissing() async throws {
        let remote = tmp.appendingPathComponent("push-upstream-remote.git")
        try require(["init", "--bare", remote.path], in: tmp)
        let repo = tmp.appendingPathComponent("push-upstream-repo")
        try require(["clone", remote.path, repo.path], in: tmp)
        try require(["config", "user.email", "gitbud@example.com"], in: repo)
        try require(["config", "user.name", "GitBud Test"], in: repo)
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try require(["push", "-u", "origin", "HEAD"], in: repo)
        try require(["switch", "-c", "feature/push"], in: repo)
        try write("feature\n", to: repo, "feature.txt")
        try commit("feature push", repo: repo)

        try await history.pushCurrentBranch(at: repo)

        let upstream = try require(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(upstream, "origin/feature/push")
        let remoteSubject = try require(["--git-dir", remote.path, "log", "--format=%s", "-1", "refs/heads/feature/push"], in: tmp).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(remoteSubject, "feature push")
    }

    func testDropCommitRemovesOnlyThatPatch() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try write("drop\n", to: repo, "drop.txt")
        try commit("drop me", repo: repo)
        let dropID = try require(["rev-parse", "HEAD"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        try write("keep\n", to: repo, "keep.txt")
        try commit("keep me", repo: repo)

        try await history.dropCommit(at: repo, commit: dropID)

        XCTAssertEqual(try logSubjects(repo), ["keep me", "base"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("drop.txt").path))
        XCTAssertEqual(try read(repo, "keep.txt"), "keep\n")
    }

    func testResetCurrentBranchToCommitCreatesBackupAndKeepsChangesInWorktree() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let baseID = try revParse("HEAD", repo: repo)
        try write("one\n", to: repo, "one.txt")
        try commit("one", repo: repo)
        try write("two\n", to: repo, "two.txt")
        try commit("two", repo: repo)
        let originalHead = try revParse("HEAD", repo: repo)

        let backup = try await history.resetCurrentBranchToCommit(at: repo, commit: baseID)

        XCTAssertEqual(try revParse("HEAD", repo: repo), baseID)
        XCTAssertEqual(try revParse(backup, repo: repo), originalHead)
        XCTAssertEqual(try logSubjects(repo), ["base"])
        XCTAssertEqual(try read(repo, "one.txt"), "one\n")
        XCTAssertEqual(try read(repo, "two.txt"), "two\n")
        let files = try await history.worktreeFiles(at: repo)
        XCTAssertTrue(files.contains { $0.path == "one.txt" && $0.displayStatus == "?" })
        XCTAssertTrue(files.contains { $0.path == "two.txt" && $0.displayStatus == "?" })
    }

    func testReflogEntriesShowRecentBranchPositions() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try write("one\n", to: repo, "one.txt")
        try commit("one", repo: repo)
        let oneID = try revParse("HEAD", repo: repo)
        try require(["reset", "--hard", "HEAD~1"], in: repo)

        let entries = try await history.reflogEntries(at: repo, limit: 5)

        XCTAssertFalse(entries.isEmpty)
        XCTAssertTrue(entries.contains { $0.commitID == oneID && $0.subject.contains("commit: one") })
        XCTAssertTrue(entries.allSatisfy { !$0.selector.isEmpty && !$0.shortCommitID.isEmpty })
    }

    func testRecoverCurrentBranchToReflogCommitCreatesBackupAndRestoresTree() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let baseID = try revParse("HEAD", repo: repo)
        try write("one\n", to: repo, "one.txt")
        try commit("one", repo: repo)
        let oneID = try revParse("HEAD", repo: repo)
        try write("two\n", to: repo, "two.txt")
        try commit("two", repo: repo)
        let twoID = try revParse("HEAD", repo: repo)
        try require(["reset", "--hard", baseID], in: repo)
        let entries = try await history.reflogEntries(at: repo)
        let entry = try XCTUnwrap(entries.first { $0.commitID == twoID })

        let backup = try await history.recoverCurrentBranch(to: entry, at: repo)
        let files = try await history.worktreeFiles(at: repo)

        XCTAssertEqual(try revParse("HEAD", repo: repo), twoID)
        XCTAssertEqual(try revParse(backup, repo: repo), baseID)
        XCTAssertEqual(try logSubjects(repo), ["two", "one", "base"])
        XCTAssertEqual(try read(repo, "one.txt"), "one\n")
        XCTAssertEqual(try read(repo, "two.txt"), "two\n")
        XCTAssertEqual(files, [])
        XCTAssertNotEqual(oneID, twoID)
    }

    func testRevertCommitCreatesInverseCommit() async throws {
        let repo = try makeRepo()
        try write("one\n", to: repo, "story.txt")
        try commit("base", repo: repo)
        try write("two\n", to: repo, "story.txt")
        try commit("change story", repo: repo)

        let result = try await history.revertCommit(at: repo, commit: "HEAD")

        XCTAssertTrue(result.completed)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(try read(repo, "story.txt"), "one\n")
        XCTAssertEqual(try logSubjects(repo).first, "Revert \"change story\"")
    }

    func testRevertCommitSurfacesConflictsAndCanContinueWithEditedContent() async throws {
        let repo = try makeRepo()
        try write("one\n", to: repo, "story.txt")
        try commit("base", repo: repo)
        try write("two\n", to: repo, "story.txt")
        try commit("target change", repo: repo)
        let target = try revParse("HEAD", repo: repo)
        try write("three\n", to: repo, "story.txt")
        try commit("later change", repo: repo)

        let result = try await history.revertCommit(at: repo, commit: target)

        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.conflicts.map(\.path), ["story.txt"])
        XCTAssertEqual(result.conflicts.first?.sections.map(\.side.rawValue), ["Your change", "REmote change"])

        try await history.resolveConflict(at: repo, path: "story.txt", content: "manual revert\n")
        try await history.continueRevert(at: repo)

        XCTAssertEqual(try read(repo, "story.txt"), "manual revert\n")
        XCTAssertEqual(try logSubjects(repo).first, "Revert \"target change\"")
    }

    func testCherryPickCommitAppliesSelectedCommit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let initialBranch = try require(["branch", "--show-current"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try await history.createBranch(at: repo, name: "feature/cherry", startPoint: "HEAD", checkout: true)
        try write("feature\n", to: repo, "feature.txt")
        try commit("feature change", repo: repo)
        let featureCommit = try revParse("HEAD", repo: repo)
        try await history.checkoutBranch(at: repo, name: initialBranch)

        let result = try await history.cherryPickCommit(at: repo, commit: featureCommit)

        XCTAssertTrue(result.completed)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(try read(repo, "feature.txt"), "feature\n")
        XCTAssertEqual(try logSubjects(repo).first, "feature change")
    }

    func testCherryPickCommitSurfacesConflictsAndCanContinueWithEditedContent() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "story.txt")
        try commit("base", repo: repo)
        let initialBranch = try require(["branch", "--show-current"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try await history.createBranch(at: repo, name: "feature/cherry-conflict", startPoint: "HEAD", checkout: true)
        try write("picked\n", to: repo, "story.txt")
        try commit("picked change", repo: repo)
        let picked = try revParse("HEAD", repo: repo)
        try await history.checkoutBranch(at: repo, name: initialBranch)
        try write("current\n", to: repo, "story.txt")
        try commit("current change", repo: repo)

        let result = try await history.cherryPickCommit(at: repo, commit: picked)

        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.conflicts.map(\.path), ["story.txt"])
        XCTAssertEqual(result.conflicts.first?.sections.map(\.side.rawValue), ["Your change", "REmote change"])

        try await history.resolveConflict(at: repo, path: "story.txt", content: "manual cherry\n")
        try await history.continueCherryPick(at: repo)

        XCTAssertEqual(try read(repo, "story.txt"), "manual cherry\n")
        XCTAssertEqual(try logSubjects(repo).first, "picked change")
    }

    func testReorderCommitsReplaysExplicitOrder() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try write("a\n", to: repo, "a.txt")
        try commit("A", repo: repo)
        let a = try revParse("HEAD", repo: repo)
        try write("b\n", to: repo, "b.txt")
        try commit("B", repo: repo)
        let b = try revParse("HEAD", repo: repo)
        try write("c\n", to: repo, "c.txt")
        try commit("C", repo: repo)
        let c = try revParse("HEAD", repo: repo)

        try await history.reorderCommits(at: repo, oldestToNewest: [c, b, a])

        XCTAssertEqual(try logSubjects(repo), ["A", "B", "C", "base"])
        XCTAssertEqual(try read(repo, "a.txt"), "a\n")
        XCTAssertEqual(try read(repo, "b.txt"), "b\n")
        XCTAssertEqual(try read(repo, "c.txt"), "c\n")
    }

    func testRewritePreviewShowsCurrentAndPlannedOrder() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try write("a\n", to: repo, "a.txt")
        try commit("A", repo: repo)
        let a = try revParse("HEAD", repo: repo)
        try write("b\n", to: repo, "b.txt")
        try commit("B", repo: repo)
        let b = try revParse("HEAD", repo: repo)
        try write("c\n", to: repo, "c.txt")
        try commit("C", repo: repo)
        let c = try revParse("HEAD", repo: repo)

        let preview = try await history.rewritePreview(at: repo, oldestToNewest: [c, b, a])

        XCTAssertEqual(preview.currentOldestToNewest.map(\.subject), ["A", "B", "C"])
        XCTAssertEqual(preview.plannedOldestToNewest.map(\.subject), ["C", "B", "A"])
        XCTAssertEqual(preview.currentOldestToNewest.map(\.currentIndex), [0, 1, 2])
        XCTAssertEqual(preview.plannedOldestToNewest.map(\.plannedIndex), [0, 1, 2])
    }

    func testResolveRebaseConflictCanTakeYourChangeAndContinue() async throws {
        let (repo, _) = try makeRebaseConflict()

        try await history.resolveConflict(at: repo, path: "story.txt", taking: .yourChange, mode: .rebase)
        try await history.continueRebase(at: repo)

        XCTAssertEqual(try read(repo, "story.txt"), "your version\n")
        let conflicts = try await history.conflicts(at: repo)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testResolveRebaseConflictCanTakeRemoteChangeAndContinue() async throws {
        let (repo, _) = try makeRebaseConflict()

        try await history.resolveConflict(at: repo, path: "story.txt", taking: .remoteChange, mode: .rebase)
        try await history.continueRebase(at: repo)

        XCTAssertEqual(try read(repo, "story.txt"), "remote version\n")
        let conflicts = try await history.conflicts(at: repo)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testResolveRebaseConflictCanUseEditedContentAndContinue() async throws {
        let (repo, _) = try makeRebaseConflict()

        try await history.resolveConflict(at: repo, path: "story.txt", content: "merged manually\n")
        try await history.continueRebase(at: repo)

        XCTAssertEqual(try read(repo, "story.txt"), "merged manually\n")
        let conflicts = try await history.conflicts(at: repo)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testResolveMergeConflictCanTakeYourChangeAndContinue() async throws {
        let (repo, targetBranch) = try makeMergeConflict()

        try await history.resolveConflict(at: repo, path: "story.txt", taking: .yourChange, mode: .merge)
        try await history.continueMerge(at: repo)

        XCTAssertEqual(try read(repo, "story.txt"), "your version\n")
        XCTAssertEqual(try logSubjects(repo).first, "Merge branch '\(targetBranch)'")
        let conflicts = try await history.conflicts(at: repo)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testResolveMergeConflictCanTakeRemoteChangeAndContinue() async throws {
        let (repo, targetBranch) = try makeMergeConflict()

        try await history.resolveConflict(at: repo, path: "story.txt", taking: .remoteChange, mode: .merge)
        try await history.continueMerge(at: repo)

        XCTAssertEqual(try read(repo, "story.txt"), "remote version\n")
        XCTAssertEqual(try logSubjects(repo).first, "Merge branch '\(targetBranch)'")
        let conflicts = try await history.conflicts(at: repo)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testResolveRevertConflictCanTakeYourChangeAndContinue() async throws {
        let (repo, _) = try await makeRevertConflict()

        try await history.resolveConflict(at: repo, path: "story.txt", taking: .yourChange, mode: .revert)
        try await history.continueRevert(at: repo)

        XCTAssertEqual(try read(repo, "story.txt"), "later version\n")
        XCTAssertEqual(try logSubjects(repo).first, "later change")
        let conflicts = try await history.conflicts(at: repo)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testResolveRevertConflictCanTakeRemoteChangeAndContinue() async throws {
        let (repo, targetSubject) = try await makeRevertConflict()

        try await history.resolveConflict(at: repo, path: "story.txt", taking: .remoteChange, mode: .revert)
        try await history.continueRevert(at: repo)

        XCTAssertEqual(try read(repo, "story.txt"), "base\n")
        XCTAssertEqual(try logSubjects(repo).first, "Revert \"\(targetSubject)\"")
        let conflicts = try await history.conflicts(at: repo)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testResolveCherryPickConflictCanTakeYourChangeAndContinue() async throws {
        let (repo, _) = try await makeCherryPickConflict()

        try await history.resolveConflict(at: repo, path: "story.txt", taking: .yourChange, mode: .cherryPick)
        try await history.continueCherryPick(at: repo)

        XCTAssertEqual(try read(repo, "story.txt"), "current version\n")
        XCTAssertEqual(try logSubjects(repo).first, "current change")
        let conflicts = try await history.conflicts(at: repo)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testResolveCherryPickConflictCanTakeRemoteChangeAndContinue() async throws {
        let (repo, _) = try await makeCherryPickConflict()

        try await history.resolveConflict(at: repo, path: "story.txt", taking: .remoteChange, mode: .cherryPick)
        try await history.continueCherryPick(at: repo)

        XCTAssertEqual(try read(repo, "story.txt"), "picked version\n")
        XCTAssertEqual(try logSubjects(repo).first, "picked change")
        let conflicts = try await history.conflicts(at: repo)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testResolveStashPopConflictCanTakeYourChangeAndFinish() async throws {
        let (repo, stashID) = try await makeStashPopConflict()

        try await history.resolveConflict(at: repo, path: "story.txt", taking: .yourChange, mode: .stashPop)
        try await history.finishStashPop(at: repo, id: stashID)

        XCTAssertEqual(try read(repo, "story.txt"), "current version\n")
        let conflicts = try await history.conflicts(at: repo)
        XCTAssertTrue(conflicts.isEmpty)
        let stashes = try await history.stashes(at: repo)
        XCTAssertTrue(stashes.isEmpty)
    }

    func testResolveStashPopConflictCanTakeRemoteChangeAndFinish() async throws {
        let (repo, stashID) = try await makeStashPopConflict()

        try await history.resolveConflict(at: repo, path: "story.txt", taking: .remoteChange, mode: .stashPop)
        try await history.finishStashPop(at: repo, id: stashID)

        XCTAssertEqual(try read(repo, "story.txt"), "stashed version\n")
        let conflicts = try await history.conflicts(at: repo)
        XCTAssertTrue(conflicts.isEmpty)
        let stashes = try await history.stashes(at: repo)
        XCTAssertTrue(stashes.isEmpty)
    }

    @discardableResult
    private func require(_ args: [String], in repo: URL) throws -> GitCommandResult {
        let result = try runner.run(args, in: repo)
        XCTAssertTrue(result.succeeded, "git \(args.joined(separator: " ")) failed: \(result.standardError)")
        return result
    }

    private func read(_ repo: URL, _ path: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    private func logSubjects(_ repo: URL) throws -> [String] {
        try require(["log", "--format=%s"], in: repo).standardOutput
            .split(separator: "\n")
            .map(String.init)
    }

    private func revParse(_ revision: String, repo: URL) throws -> String {
        try require(["rev-parse", revision], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeRebaseConflict() throws -> (URL, URL) {
        let remote = tmp.appendingPathComponent("remote-\(UUID().uuidString).git")
        try require(["init", "--bare", remote.path], in: tmp)

        let a = tmp.appendingPathComponent("a-\(UUID().uuidString)")
        let b = tmp.appendingPathComponent("b-\(UUID().uuidString)")
        try require(["clone", remote.path, a.path], in: tmp)
        try require(["clone", remote.path, b.path], in: tmp)
        try require(["config", "user.email", "a@example.com"], in: a)
        try require(["config", "user.name", "A"], in: a)
        try require(["config", "user.email", "b@example.com"], in: b)
        try require(["config", "user.name", "B"], in: b)

        try write("base\n", to: a, "story.txt")
        try commit("seed", repo: a)
        try require(["push", "-u", "origin", "HEAD"], in: a)
        try require(["pull"], in: b)

        try write("your version\n", to: b, "story.txt")
        try commit("your edit", repo: b)

        try write("remote version\n", to: a, "story.txt")
        try commit("remote edit", repo: a)
        try require(["push"], in: a)

        _ = try runner.run(["pull", "--rebase"], in: b)
        return (b, a)
    }

    private func makeMergeConflict() throws -> (repo: URL, targetBranch: String) {
        let repo = try makeRepo("merge-conflict-\(UUID().uuidString)")
        try write("base\n", to: repo, "story.txt")
        try commit("seed", repo: repo)
        let currentBranch = try require(["branch", "--show-current"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let targetBranch = "feature/merge-side"

        try require(["switch", "-c", targetBranch], in: repo)
        try write("remote version\n", to: repo, "story.txt")
        try commit("remote edit", repo: repo)
        try require(["switch", currentBranch], in: repo)
        try write("your version\n", to: repo, "story.txt")
        try commit("your edit", repo: repo)

        let result = try runner.run(["merge", targetBranch], in: repo)
        XCTAssertFalse(result.succeeded)
        return (repo, targetBranch)
    }

    private func makeRevertConflict() async throws -> (repo: URL, targetSubject: String) {
        let repo = try makeRepo("revert-conflict-\(UUID().uuidString)")
        try write("base\n", to: repo, "story.txt")
        try commit("base", repo: repo)
        let targetSubject = "target change"
        try write("target version\n", to: repo, "story.txt")
        try commit(targetSubject, repo: repo)
        let target = try revParse("HEAD", repo: repo)
        try write("later version\n", to: repo, "story.txt")
        try commit("later change", repo: repo)

        let result = try await history.revertCommit(at: repo, commit: target)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.conflicts.first?.sections.map(\.side.rawValue), ["Your change", "REmote change"])
        return (repo, targetSubject)
    }

    private func makeCherryPickConflict() async throws -> (repo: URL, pickedCommit: String) {
        let repo = try makeRepo("cherry-conflict-\(UUID().uuidString)")
        try write("base\n", to: repo, "story.txt")
        try commit("base", repo: repo)
        let initialBranch = try require(["branch", "--show-current"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)

        try await history.createBranch(at: repo, name: "feature/cherry-side", startPoint: "HEAD", checkout: true)
        try write("picked version\n", to: repo, "story.txt")
        try commit("picked change", repo: repo)
        let picked = try revParse("HEAD", repo: repo)
        try await history.checkoutBranch(at: repo, name: initialBranch)
        try write("current version\n", to: repo, "story.txt")
        try commit("current change", repo: repo)

        let result = try await history.cherryPickCommit(at: repo, commit: picked)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.conflicts.first?.sections.map(\.side.rawValue), ["Your change", "REmote change"])
        return (repo, picked)
    }

    private func makeStashPopConflict() async throws -> (repo: URL, stashID: String) {
        let repo = try makeRepo("stash-conflict-\(UUID().uuidString)")
        try write("base\n", to: repo, "story.txt")
        try commit("base", repo: repo)
        try write("stashed version\n", to: repo, "story.txt")
        try await history.saveStash(at: repo, message: "conflicting stash")
        let stashes = try await history.stashes(at: repo)
        let stash = try XCTUnwrap(stashes.first)
        try write("current version\n", to: repo, "story.txt")
        try commit("current change", repo: repo)

        let result = try await history.popStash(at: repo, id: stash.id)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.conflicts.first?.sections.map(\.side.rawValue), ["Your change", "REmote change"])
        return (repo, stash.id)
    }
}
#endif
