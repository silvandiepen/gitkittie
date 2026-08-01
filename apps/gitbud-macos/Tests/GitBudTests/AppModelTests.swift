import XCTest
import GitKit
@testable import GitBudCore

@MainActor
final class AppModelTests: XCTestCase {
    private let runner = GitProcessRunner()
    private var tmp: URL!

    override func setUpWithError() throws {
        GitBudSettingsStore().resetProtectedBranchPatterns()
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gitbud-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testOpenRepositoryLoadsGraphDiffAndFileHistory() async throws {
        let repo = try makeRepo()
        try write("one\n", to: repo, "App.swift")
        try commit("feat: seed", repo: repo)
        try write("one\ntwo\n", to: repo, "App.swift")
        try commit("feat: update", repo: repo)

        let suiteName = "app.hakobs.gitbud.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GitBudSettingsStore(defaults: defaults)
        let model = AppModel(settingsStore: store)
        await model.openRepository(repo)

        XCTAssertEqual(model.repositoryName, "repo")
        XCTAssertEqual(model.commits.first?.subject, "feat: update")
        XCTAssertTrue(model.changedFiles.contains { $0.path == "App.swift" })
        XCTAssertTrue(model.fileDiffs.contains { $0.path == "App.swift" })
        XCTAssertFalse(model.fileHistory.isEmpty)
        XCTAssertEqual(model.fileBlame.map(\.content), ["one", "two"])
        XCTAssertEqual(model.fileBlame.last?.summary, "feat: update")
        XCTAssertFalse(model.hasConflicts)
    }

    func testAppModelSearchHistorySelectsRealGitMatches() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "story.txt")
        try commit("seed story", repo: repo)
        try write("base\nneedle\n", to: repo, "story.txt")
        try require(["add", "-A"], in: repo)
        try require(["commit", "-m", "feat: parser cleanup", "-m", "Body mentions searchable context."], in: repo)
        let parserCommit = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try write("notes\n", to: repo, "notes.txt")
        try commit("docs: notes", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        model.historySearchText = "PARSER"
        model.historySearchMode = .message
        model.searchHistory()
        await waitForHistorySearch(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.historySearchDidRun)
        XCTAssertEqual(model.historySearchResults.map(\.id), [parserCommit])
        XCTAssertEqual(model.focusedCommitID, parserCommit)
        XCTAssertEqual(model.changedFiles.map(\.path), ["story.txt"])
        XCTAssertEqual(model.statusMessage, "Found 1 history matches.")

        model.clearHistorySearch()
        XCTAssertFalse(model.historySearchDidRun)
        XCTAssertEqual(model.visibleCommits.count, model.commits.count)

        model.historySearchText = "needle"
        model.historySearchMode = .changes
        model.searchHistory()
        await waitForHistorySearch(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.historySearchResults.map(\.id), [parserCommit])
    }

    func testAppModelSelectFileLoadsBlameForThatFile() async throws {
        let repo = try makeRepo()
        try write("left\n", to: repo, "left.txt")
        try write("right\n", to: repo, "right.txt")
        try commit("seed files", repo: repo)
        try write("left\nLEFT\n", to: repo, "left.txt")
        try write("right\nRIGHT\n", to: repo, "right.txt")
        try commit("update files", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        let right = try XCTUnwrap(model.changedFiles.first { $0.path == "right.txt" })
        model.selectFile(right)
        await waitForSelectedBlame(model, path: "right.txt")

        XCTAssertEqual(model.selectedFilePath, "right.txt")
        XCTAssertEqual(model.fileBlame.map(\.content), ["right", "RIGHT"])
        XCTAssertEqual(model.fileBlame.last?.summary, "update files")
    }

    func testOpenRepositorySurfacesConflictsWithClearLabels() async throws {
        let b = try makeRebaseConflict()

        let model = AppModel()
        await model.openRepository(b)

        XCTAssertEqual(model.conflicts.first?.path, "conflict.txt")
        XCTAssertEqual(model.conflicts.first?.sections.map(\.side.rawValue), ["Your change", "REmote change"])
    }

    func testAppModelSquashSelectedCommitsLandsOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try write("one\n", to: repo, "one.txt")
        try commit("one", repo: repo)
        try write("two\n", to: repo, "two.txt")
        try commit("two", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        model.selectedCommitIDs = model.commits.prefix(2).map(\.id)
        model.squashSelectedCommits()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try logSubjects(repo), ["Squash: two", "base"])
        XCTAssertEqual(try read(repo, "one.txt"), "one\n")
        XCTAssertEqual(try read(repo, "two.txt"), "two\n")
        XCTAssertNotNil(model.safetyBranchName)
    }

    func testAppModelSquashSelectedCommitsRequiresCleanWorkingTree() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try write("one\n", to: repo, "one.txt")
        try commit("one", repo: repo)
        try write("two\n", to: repo, "two.txt")
        try commit("two", repo: repo)
        let originalHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try write("dirty\n", to: repo, "dirty.txt")

        let model = AppModel()
        await model.openRepository(repo)
        model.selectedCommitIDs = model.commits.prefix(2).map(\.id)
        model.squashSelectedCommits()
        await waitForRewrite(model)

        XCTAssertEqual(model.errorMessage, "The working tree must be clean before rewriting history.")
        XCTAssertEqual(model.statusMessage, "Rewrite needs attention.")
        XCTAssertEqual(try require(["rev-parse", "HEAD"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), originalHead)
        XCTAssertEqual(try logSubjects(repo), ["two", "one", "base"])
        XCTAssertEqual(try read(repo, "dirty.txt"), "dirty\n")
    }

    func testAppModelSplitSelectedFilesLandsOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try write("selected\n", to: repo, "selected.txt")
        try write("remaining\n", to: repo, "remaining.txt")
        try commit("mixed", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        model.selectedSplitPaths = ["selected.txt"]
        model.splitHeadCommitBySelectedFiles()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try logSubjects(repo), ["Keep remaining changes", "Split selected files", "base"])
        let selectedFiles = try require(["show", "--format=", "--name-only", "HEAD~1"], in: repo).standardOutput
        let remainingFiles = try require(["show", "--format=", "--name-only", "HEAD"], in: repo).standardOutput
        XCTAssertTrue(selectedFiles.contains("selected.txt"))
        XCTAssertFalse(selectedFiles.contains("remaining.txt"))
        XCTAssertTrue(remainingFiles.contains("remaining.txt"))
        XCTAssertFalse(remainingFiles.contains("selected.txt"))
    }

    func testAppModelSplitNonHeadSelectedCommitByFilesLandsOnGit() async throws {
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

        let model = AppModel()
        await model.openRepository(repo)
        model.focusedCommitID = mixed
        model.selectedSplitPaths = ["selected.txt"]
        model.splitHeadCommitBySelectedFiles()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try logSubjects(repo), ["later work", "Keep remaining changes", "Split selected files", "base"])
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

    func testAppModelSplitSelectedCommitRequiresSelectedFileOrHunk() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try write("selected\n", to: repo, "selected.txt")
        try write("remaining\n", to: repo, "remaining.txt")
        try commit("mixed", repo: repo)
        let originalHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let model = AppModel()
        await model.openRepository(repo)
        model.splitHeadCommitBySelectedFiles()

        XCTAssertFalse(model.isRewriting)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Select at least one file or hunk before splitting a commit.")
        XCTAssertNil(model.safetyBranchName)
        XCTAssertEqual(try require(["rev-parse", "HEAD"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), originalHead)
        XCTAssertEqual(try logSubjects(repo), ["mixed", "base"])
        XCTAssertEqual(try read(repo, "selected.txt"), "selected\n")
        XCTAssertEqual(try read(repo, "remaining.txt"), "remaining\n")
    }

    func testAppModelSplitSelectedHunksLandsOnGit() async throws {
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

        let model = AppModel()
        await model.openRepository(repo)
        XCTAssertTrue(model.fileDiffs.flatMap(\.hunks).map(\.id).contains("story.txt:0"))
        model.selectedSplitHunkIDs = ["story.txt:0"]
        model.splitHeadCommitBySelectedFiles()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try logSubjects(repo), ["Keep remaining changes", "Split selected hunks", "base"])
        let selectedPatch = try require(["show", "--format=", "HEAD~1"], in: repo).standardOutput
        let remainingPatch = try require(["show", "--format=", "HEAD"], in: repo).standardOutput
        XCTAssertTrue(selectedPatch.contains("+ONE"))
        XCTAssertFalse(selectedPatch.contains("+ELEVEN"))
        XCTAssertTrue(remainingPatch.contains("+ELEVEN"))
        XCTAssertFalse(remainingPatch.contains("+ONE"))
    }

    func testAppModelSplitNonHeadSelectedCommitByHunksLandsOnGit() async throws {
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

        let model = AppModel()
        await model.openRepository(repo)
        let mixedNode = try XCTUnwrap(model.commits.first { $0.id == mixed })
        model.selectCommit(mixedNode)
        await waitForSelectedDiff(model, path: "story.txt")
        model.selectedSplitHunkIDs = ["story.txt:0"]
        model.splitHeadCommitBySelectedFiles()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try logSubjects(repo), ["later work", "Keep remaining changes", "Split selected hunks", "base"])
        let selectedPatch = try require(["show", "--format=", "HEAD~2"], in: repo).standardOutput
        let remainingPatch = try require(["show", "--format=", "HEAD~1"], in: repo).standardOutput
        XCTAssertTrue(selectedPatch.contains("+ONE"))
        XCTAssertFalse(selectedPatch.contains("+ELEVEN"))
        XCTAssertTrue(remainingPatch.contains("+ELEVEN"))
        XCTAssertFalse(remainingPatch.contains("+ONE"))
        XCTAssertEqual(try read(repo, "later.txt"), "later\n")
    }

    func testAppModelMagicDraftCanBeAppliedToGitCommit() async throws {
        let repo = try makeRepo()
        try write("before\n", to: repo, "story.txt")
        try commit("rough message", repo: repo)
        try write("after\n", to: repo, "story.txt")
        try commit("needs magic", repo: repo)
        let magic = AIPontMagicService(
            transport: MockAIPontTransport(body: #"{"choices":[{"message":{"content":"feat: polish story file\n\nClarify the story fixture."}}]}"#)
        )

        let model = AppModel(magicService: magic)
        await model.openRepository(repo)
        model.magicAPIKey = "test-key"
        model.magicModel = "gpt-test"
        model.magicEndpoint = "https://example.com/v1/chat/completions"
        model.draftMagicCommitMessage()
        await waitForMagic(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.magicDraft, "feat: polish story file\n\nClarify the story fixture.")
        XCTAssertNil(model.safetyBranchName)
        XCTAssertEqual(try logSubjects(repo).first, "needs magic")
        model.editHeadCommitMessage()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try logSubjects(repo).first, "feat: polish story file")
    }

    func testAppModelMagicDraftRequiresBYOKAndDoesNotChangeGit() async throws {
        let repo = try makeRepo()
        try write("before\n", to: repo, "story.txt")
        try commit("rough message", repo: repo)
        let originalHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let model = AppModel(
            magicService: AIPontMagicService(
                transport: MockAIPontTransport(body: #"{"choices":[{"message":{"content":"feat: unused"}}]}"#)
            )
        )
        await model.openRepository(repo)
        model.magicAPIKey = " "
        model.magicModel = "gpt-test"
        model.magicEndpoint = "https://example.com/v1/chat/completions"
        model.draftMagicCommitMessage()
        await waitForMagic(model)

        XCTAssertEqual(model.statusMessage, "Magic needs attention.")
        XCTAssertEqual(model.errorMessage, "Add your AI provider API key before using Magic.")
        XCTAssertEqual(model.magicDraft, "")
        XCTAssertNil(model.safetyBranchName)
        XCTAssertEqual(try require(["rev-parse", "HEAD"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), originalHead)
        XCTAssertEqual(try logSubjects(repo).first, "rough message")
    }

    func testAppModelMagicRewriteDraftCanBeAppliedToSquash() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try write("one\n", to: repo, "one.txt")
        try commit("rough one", repo: repo)
        try write("two\n", to: repo, "two.txt")
        try commit("rough two", repo: repo)
        let magic = AIPontMagicService(
            transport: MockAIPontTransport(body: #"{"choices":[{"message":{"content":"feat: combine focused work\n\nMerge the selected related changes."}}]}"#)
        )

        let model = AppModel(magicService: magic)
        await model.openRepository(repo)
        model.magicAPIKey = "test-key"
        model.magicModel = "gpt-test"
        model.magicEndpoint = "https://example.com/v1/chat/completions"
        model.selectedCommitIDs = model.commits.prefix(2).map(\.id)
        model.draftMagicRewriteMessage()
        await waitForMagic(model)
        model.squashSelectedCommits()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try logSubjects(repo), ["feat: combine focused work", "base"])
        XCTAssertEqual(try read(repo, "one.txt"), "one\n")
        XCTAssertEqual(try read(repo, "two.txt"), "two\n")
    }

    func testAppModelMagicRewriteDraftCanBeAppliedToSplitCommit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try write("selected\n", to: repo, "selected.txt")
        try write("remaining\n", to: repo, "remaining.txt")
        try commit("mixed", repo: repo)
        let magic = AIPontMagicService(
            transport: MockAIPontTransport(body: #"{"choices":[{"message":{"content":"feat: isolate selected file\n\nMove selected file changes into their own commit."}}]}"#)
        )

        let model = AppModel(magicService: magic)
        await model.openRepository(repo)
        model.magicAPIKey = "test-key"
        model.magicModel = "gpt-test"
        model.magicEndpoint = "https://example.com/v1/chat/completions"
        model.selectedSplitPaths = ["selected.txt"]
        model.draftMagicRewriteMessage()
        await waitForMagic(model)
        model.splitHeadCommitBySelectedFiles()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try logSubjects(repo), ["Keep remaining changes", "feat: isolate selected file", "base"])
        let selectedFiles = try require(["show", "--format=", "--name-only", "HEAD~1"], in: repo).standardOutput
        XCTAssertTrue(selectedFiles.contains("selected.txt"))
        XCTAssertFalse(selectedFiles.contains("remaining.txt"))
    }

    func testAppModelPersistsMagicSettingsWithoutBackend() throws {
        let suiteName = "app.hakobs.gitbud.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = KeychainService(service: suiteName, account: "magic-api-key")
        defer { try? keychain.delete() }
        let store = GitBudSettingsStore(defaults: defaults, magicKeychain: keychain)

        var model = AppModel(settingsStore: store)
        model.magicProvider = .anthropic
        model.magicModel = "claude-test"
        model.magicEndpoint = "https://example.com/v1/messages"
        model.magicAPIKey = "secret-test-key"
        model.saveMagicSettings()
        model.protectedBranchPatternsText = "main, development\nfeature/protected\nrelease/*\nmain"
        model.saveProtectedBranchPolicy()

        model = AppModel(settingsStore: store)
        XCTAssertEqual(model.magicProvider, .anthropic)
        XCTAssertEqual(model.magicModel, "claude-test")
        XCTAssertEqual(model.magicEndpoint, "https://example.com/v1/messages")
        XCTAssertEqual(model.magicAPIKey, "secret-test-key")
        XCTAssertEqual(model.protectedBranchPatterns, ["main", "development", "feature/protected", "release/*"])
        XCTAssertEqual(model.protectedBranchPatternsText, "main\ndevelopment\nfeature/protected\nrelease/*")
    }

    func testAppModelPersistsProviderTokenInKeychainWithoutBackend() throws {
        let suiteName = "app.hakobs.gitbud.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let providerKeychain = KeychainService(service: suiteName, account: "provider-access-token")
        defer { try? providerKeychain.delete() }
        let store = GitBudSettingsStore(defaults: defaults, providerKeychain: providerKeychain)

        var model = AppModel(settingsStore: store)
        model.remoteAccessToken = "provider-secret-token"
        model.saveProviderAccessToken()
        XCTAssertEqual(model.statusMessage, "Provider token saved.")

        model = AppModel(settingsStore: store)
        XCTAssertEqual(model.remoteAccessToken, "provider-secret-token")

        model.clearProviderAccessToken()
        XCTAssertEqual(model.remoteAccessToken, "")
        XCTAssertEqual(model.statusMessage, "Provider token cleared.")

        model = AppModel(settingsStore: store)
        XCTAssertEqual(model.remoteAccessToken, "")
    }

    func testAppModelConflictActionTitlesMatchActiveConflictMode() {
        let model = AppModel()

        model.activeConflictMode = .merge
        XCTAssertEqual(model.conflictContinueButtonTitle, "Continue Merge")
        XCTAssertEqual(model.conflictAbortButtonTitle, "Abort Merge")

        model.activeConflictMode = .rebase
        XCTAssertEqual(model.conflictContinueButtonTitle, "Continue Rebase")
        XCTAssertEqual(model.conflictAbortButtonTitle, "Abort Rebase")

        model.activeConflictMode = .revert
        XCTAssertEqual(model.conflictContinueButtonTitle, "Continue Revert")
        XCTAssertEqual(model.conflictAbortButtonTitle, "Abort Revert")

        model.activeConflictMode = .cherryPick
        XCTAssertEqual(model.conflictContinueButtonTitle, "Continue Cherry-pick")
        XCTAssertEqual(model.conflictAbortButtonTitle, "Abort Cherry-pick")

        model.activeConflictMode = .stashPop
        XCTAssertEqual(model.conflictContinueButtonTitle, "Finish Stash Pop")
        XCTAssertEqual(model.conflictAbortButtonTitle, "Abort Stash Pop")
    }

    func testAppModelClonesRemoteIntoManagedStorageAndOpensIt() async throws {
        let remote = tmp.appendingPathComponent("managed-remote.git")
        try require(["init", "--bare", remote.path], in: tmp)
        let source = tmp.appendingPathComponent("source")
        try require(["clone", remote.path, source.path], in: tmp)
        try configureIdentity(source, name: "GitBud Remote")
        try write("remote file\n", to: source, "remote.txt")
        try commit("remote seed", repo: source)
        try require(["push", "-u", "origin", "HEAD"], in: source)
        let managedRoot = tmp.appendingPathComponent("managed-checkouts")

        let model = AppModel(managedRepositoryRoot: managedRoot)
        model.remoteURLString = remote.path
        model.cloneRemoteRepository()
        await waitForClone(model)

        XCTAssertNil(model.errorMessage)
        let opened = try XCTUnwrap(model.repositoryURL)
        XCTAssertTrue(opened.path.hasPrefix(managedRoot.path))
        XCTAssertEqual(model.commits.first?.subject, "remote seed")
        XCTAssertEqual(try read(opened, "remote.txt"), "remote file\n")
        let origin = try require(["remote", "get-url", "origin"], in: opened).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(origin, remote.path)
    }

    func testAppModelLoadsProviderRepositoriesThroughGitPontPicker() async throws {
        let first = GitHubRepo(
            name: "gitbud",
            fullName: "sil/gitbud",
            ownerLogin: "sil",
            cloneURL: URL(string: "https://github.com/sil/gitbud.git")!,
            defaultBranch: "main",
            isPrivate: false
        )
        let second = GitHubRepo(
            name: "secret",
            fullName: "sil/secret",
            ownerLogin: "sil",
            cloneURL: URL(string: "https://github.com/sil/secret.git")!,
            defaultBranch: "develop",
            isPrivate: true
        )
        let model = AppModel(providerRepositoryLister: { token in
            guard token == "test-token" else { throw GitHubReposError.requestFailed(status: 401) }
            return [first, second]
        })

        model.remoteAccessToken = "test-token"
        model.loadProviderRepositories()
        await waitForProviderRepositories(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.providerRepositories.map(\.fullName), ["sil/gitbud", "sil/secret"])
        XCTAssertEqual(model.selectedProviderRepositoryID, "sil/gitbud")
        XCTAssertEqual(model.remoteURLString, "https://github.com/sil/gitbud.git")

        model.selectProviderRepository(second)
        XCTAssertEqual(model.selectedProviderRepository?.fullName, "sil/secret")
        XCTAssertEqual(model.remoteURLString, "https://github.com/sil/secret.git")
    }

    func testAppModelSelectingProviderRepositoryClearsStalePullRequestState() {
        let first = GitHubRepo(
            name: "gitbud",
            fullName: "sil/gitbud",
            ownerLogin: "sil",
            cloneURL: URL(string: "https://github.com/sil/gitbud.git")!,
            defaultBranch: "main",
            isPrivate: false
        )
        let second = GitHubRepo(
            name: "secret",
            fullName: "sil/secret",
            ownerLogin: "sil",
            cloneURL: URL(string: "https://github.com/sil/secret.git")!,
            defaultBranch: "develop",
            isPrivate: true
        )
        let stalePullRequest = GitHubPullRequest(
            number: 22,
            title: "feat: stale review",
            url: URL(string: "https://github.com/sil/gitbud/pull/22")!,
            head: "feature/stale",
            headSHA: "stale-head",
            base: "main"
        )
        let staleFile = GitHubPullRequestFile(path: "Old.swift", status: "modified", additions: 1, deletions: 0, changes: 1)
        let model = AppModel()

        model.providerRepositories = [first, second]
        model.selectProviderRepository(first)
        model.providerPullRequests = [stalePullRequest]
        model.selectedProviderPullRequestNumber = stalePullRequest.number
        model.providerPullRequestReviewSummary = GitHubPullRequestReviewSummary(
            pullRequest: stalePullRequest,
            additions: 1,
            deletions: 0,
            changedFiles: 1,
            commitCount: 1,
            issueComments: 0,
            reviewComments: 1,
            mergeable: true,
            mergeableState: "clean",
            approvals: 0,
            requestedChanges: 0,
            reviewCommentThreads: 1,
            files: [staleFile],
            inlineComments: [
                GitHubPullRequestInlineComment(id: 2201, path: "Old.swift", body: "stale", authorLogin: "reviewer", line: 1, side: "RIGHT")
            ]
        )
        model.selectedProviderPullRequestFilePath = "Old.swift"
        model.selectedProviderInlineCommentID = 2201
        model.providerInlineCommentDraft = "Do not leak this comment."
        model.providerInlineCommentLineText = "1"
        model.providerInlineReplyDraft = "Do not leak this reply."
        model.providerReviewBody = "Do not leak this review."
        model.providerSubmittedReview = GitHubPullRequestSubmittedReview(id: 33, state: "APPROVED", body: "stale", authorLogin: "sil")

        model.selectProviderRepository(second)

        XCTAssertEqual(model.selectedProviderRepositoryID, second.id)
        XCTAssertEqual(model.remoteURLString, "https://github.com/sil/secret.git")
        XCTAssertEqual(model.pullRequestBaseBranch, "develop")
        XCTAssertTrue(model.providerPullRequests.isEmpty)
        XCTAssertNil(model.selectedProviderPullRequestNumber)
        XCTAssertNil(model.providerPullRequestReviewSummary)
        XCTAssertNil(model.selectedProviderPullRequestFilePath)
        XCTAssertNil(model.selectedProviderInlineCommentID)
        XCTAssertEqual(model.providerInlineCommentDraft, "")
        XCTAssertEqual(model.providerInlineCommentLineText, "")
        XCTAssertEqual(model.providerInlineReplyDraft, "")
        XCTAssertEqual(model.providerReviewBody, "")
        XCTAssertNil(model.providerSubmittedReview)
    }

    func testAppModelConnectsProviderAccountThroughDeviceFlow() async throws {
        let suiteName = "app.hakobs.gitbud.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let providerKeychain = KeychainService(service: suiteName, account: "provider-access-token")
        defer { try? providerKeychain.delete() }
        let store = GitBudSettingsStore(defaults: defaults, providerKeychain: providerKeychain)
        let authorization = GitHubDeviceAuthorization(
            deviceCode: "device-abc",
            userCode: "ABCD-EFGH",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresIn: 900,
            interval: 5
        )
        let capture = ProviderOAuthCapture()
        let model = AppModel(
            settingsStore: store,
            providerOAuthAuthorizationRequester: { clientID in
                capture.requestClientID = clientID
                return authorization
            },
            providerOAuthTokenWaiter: { clientID, requestedAuthorization in
                capture.waitClientID = clientID
                capture.authorization = requestedAuthorization
                return "oauth-token"
            },
            providerLoginLoader: { token in
                capture.loginToken = token
                return "sil"
            }
        )

        model.providerOAuthClientID = "client-123"
        model.requestProviderConnectionCode()
        await waitForProviderConnection(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(capture.requestClientID, "client-123")
        XCTAssertEqual(model.providerOAuthAuthorization, authorization)
        XCTAssertEqual(model.statusMessage, "Enter code ABCD-EFGH on GitHub.")

        model.finishProviderConnection()
        await waitForProviderConnection(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(capture.waitClientID, "client-123")
        XCTAssertEqual(capture.authorization, authorization)
        XCTAssertEqual(capture.loginToken, "oauth-token")
        XCTAssertEqual(model.remoteAccessToken, "oauth-token")
        XCTAssertEqual(model.providerLogin, "sil")
        XCTAssertEqual(model.statusMessage, "Provider connected as sil.")
        XCTAssertEqual(AppModel(settingsStore: store).remoteAccessToken, "oauth-token")
    }

    func testAppModelClonesSelectedProviderRepositoryIntoManagedStorage() async throws {
        let remote = tmp.appendingPathComponent("provider-remote.git")
        try require(["init", "--bare", remote.path], in: tmp)
        let source = tmp.appendingPathComponent("provider-source")
        try require(["clone", remote.path, source.path], in: tmp)
        try configureIdentity(source, name: "Provider Source")
        try write("provider file\n", to: source, "provider.txt")
        try commit("provider seed", repo: source)
        try require(["push", "-u", "origin", "HEAD"], in: source)
        let managedRoot = tmp.appendingPathComponent("provider-checkouts")
        let providerRepo = GitHubRepo(
            name: "provider-remote",
            fullName: "sil/provider-remote",
            ownerLogin: "sil",
            cloneURL: URL(fileURLWithPath: remote.path),
            defaultBranch: "main",
            isPrivate: true
        )
        let model = AppModel(
            managedRepositoryRoot: managedRoot,
            providerRepositoryLister: { token in
                guard token == "provider-token" else { throw GitHubReposError.requestFailed(status: 401) }
                return [providerRepo]
            }
        )

        model.remoteAccessToken = "provider-token"
        model.loadProviderRepositories()
        await waitForProviderRepositories(model)
        model.cloneSelectedProviderRepository()
        await waitForClone(model)

        XCTAssertNil(model.errorMessage)
        let opened = try XCTUnwrap(model.repositoryURL)
        XCTAssertTrue(opened.path.hasPrefix(managedRoot.path))
        XCTAssertEqual(model.commits.first?.subject, "provider seed")
        XCTAssertEqual(try read(opened, "provider.txt"), "provider file\n")
        let origin = try require(["remote", "get-url", "origin"], in: opened).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(origin, remote.path)
    }

    func testAppModelCreatesDraftPullRequestForSelectedProviderRepository() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try require(["switch", "-c", "feature/pr-cleanup"], in: repo)
        try write("cleanup\n", to: repo, "cleanup.txt")
        try commit("cleanup", repo: repo)
        let providerRepo = GitHubRepo(
            name: "gitbud",
            fullName: "sil/gitbud",
            ownerLogin: "sil",
            cloneURL: URL(string: "https://github.com/sil/gitbud.git")!,
            defaultBranch: "main",
            isPrivate: false
        )
        let capture = PullRequestCapture()
        let model = AppModel(pullRequestCreator: { draft, token in
            capture.draft = draft
            capture.token = token
            return GitHubPullRequest(
                number: 77,
                title: draft.title,
                url: URL(string: "https://github.com/sil/gitbud/pull/77")!,
                head: draft.head,
                base: draft.base
            )
        })

        await model.openRepository(repo)
        model.providerRepositories = [providerRepo]
        model.selectProviderRepository(providerRepo)
        model.remoteAccessToken = "pr-token"
        model.pullRequestTitle = "feat: cleanup history"
        model.pullRequestBody = "Review the rewritten branch."
        model.createDraftPullRequest()
        await waitForPullRequest(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(capture.token, "pr-token")
        XCTAssertEqual(capture.draft?.repositoryFullName, "sil/gitbud")
        XCTAssertEqual(capture.draft?.title, "feat: cleanup history")
        XCTAssertEqual(capture.draft?.body, "Review the rewritten branch.")
        XCTAssertEqual(capture.draft?.head, "feature/pr-cleanup")
        XCTAssertEqual(capture.draft?.base, "main")
        XCTAssertEqual(capture.draft?.draft, true)
        XCTAssertEqual(model.createdPullRequestURL, URL(string: "https://github.com/sil/gitbud/pull/77"))
        XCTAssertEqual(model.statusMessage, "Draft pull request #77 created.")
    }

    func testAppModelCreateDraftPullRequestRequiresProviderTokenBeforeCallingProvider() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try require(["switch", "-c", "feature/pr-guard"], in: repo)
        let providerRepo = GitHubRepo(
            name: "gitbud",
            fullName: "sil/gitbud",
            ownerLogin: "sil",
            cloneURL: URL(string: "https://github.com/sil/gitbud.git")!,
            defaultBranch: "main",
            isPrivate: false
        )
        let capture = PullRequestCapture()
        let model = AppModel(pullRequestCreator: { draft, token in
            capture.draft = draft
            capture.token = token
            return GitHubPullRequest(
                number: 78,
                title: draft.title,
                url: URL(string: "https://github.com/sil/gitbud/pull/78")!,
                head: draft.head,
                base: draft.base
            )
        })

        await model.openRepository(repo)
        model.providerRepositories = [providerRepo]
        model.selectProviderRepository(providerRepo)
        model.remoteAccessToken = "   "
        model.pullRequestTitle = "feat: guarded draft"
        model.pullRequestBody = "Should not be sent without a provider token."
        model.createDraftPullRequest()

        XCTAssertFalse(model.isCreatingPullRequest)
        XCTAssertNil(capture.draft)
        XCTAssertNil(capture.token)
        XCTAssertNil(model.createdPullRequestURL)
        XCTAssertEqual(model.pullRequestTitle, "feat: guarded draft")
        XCTAssertEqual(model.pullRequestBody, "Should not be sent without a provider token.")
        XCTAssertEqual(model.statusMessage, "Enter a provider token before creating a pull request.")
    }

    func testAppModelLoadsPullRequestsForSelectedProviderRepository() async throws {
        let providerRepo = GitHubRepo(
            name: "gitbud",
            fullName: "sil/gitbud",
            ownerLogin: "sil",
            cloneURL: URL(string: "https://github.com/sil/gitbud.git")!,
            defaultBranch: "main",
            isPrivate: false
        )
        let capture = PullRequestListCapture()
        let model = AppModel(pullRequestLister: { repositoryFullName, token in
            capture.repositoryFullName = repositoryFullName
            capture.token = token
            return [
                GitHubPullRequest(
                    number: 88,
                    title: "feat: review rewrite",
                    url: URL(string: "https://github.com/sil/gitbud/pull/88")!,
                    head: "feature/rewrite",
                    base: "main",
                    state: "open",
                    isDraft: true
                )
            ]
        })

        model.providerRepositories = [providerRepo]
        model.selectProviderRepository(providerRepo)
        model.remoteAccessToken = "pr-list-token"
        model.loadProviderPullRequests()
        await waitForPullRequestList(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(capture.repositoryFullName, "sil/gitbud")
        XCTAssertEqual(capture.token, "pr-list-token")
        XCTAssertEqual(model.providerPullRequests.map(\.number), [88])
        XCTAssertEqual(model.providerPullRequests.first?.title, "feat: review rewrite")
        XCTAssertEqual(model.providerPullRequests.first?.isDraft, true)
        XCTAssertEqual(model.statusMessage, "Loaded open pull requests.")
    }

    func testAppModelLoadsSelectedPullRequestReviewSummary() async throws {
        let providerRepo = GitHubRepo(
            name: "gitbud",
            fullName: "sil/gitbud",
            ownerLogin: "sil",
            cloneURL: URL(string: "https://github.com/sil/gitbud.git")!,
            defaultBranch: "main",
            isPrivate: false
        )
        let pullRequest = GitHubPullRequest(
            number: 88,
            title: "feat: review rewrite",
            url: URL(string: "https://github.com/sil/gitbud/pull/88")!,
            head: "feature/rewrite",
            headSHA: "abc123",
            base: "main",
            state: "open",
            isDraft: false
        )
        let capture = PullRequestReviewSummaryCapture()
        let replyCapture = PullRequestInlineReplyCapture()
        let inlineCommentCapture = PullRequestInlineCommentCreateCapture()
        let reviewCapture = PullRequestReviewSubmitCapture()
        let model = AppModel(
            pullRequestLister: { _, _ in [pullRequest] },
            pullRequestReviewSummaryLoader: { repositoryFullName, number, token in
                capture.repositoryFullName = repositoryFullName
                capture.number = number
                capture.token = token
                return GitHubPullRequestReviewSummary(
                    pullRequest: pullRequest,
                    additions: 21,
                    deletions: 5,
                    changedFiles: 4,
                    commitCount: 3,
                    issueComments: 2,
                    reviewComments: 6,
                    mergeable: true,
                    mergeableState: "clean",
                    approvals: 1,
                    requestedChanges: 0,
                    reviewCommentThreads: 2,
                    files: [
                        GitHubPullRequestFile(
                            path: "GitBud/App/AppModel.swift",
                            status: "modified",
                            additions: 18,
                            deletions: 3,
                            changes: 21,
                            patch: "@@ -1 +1 @@\n-old\n+new"
                        ),
                        GitHubPullRequestFile(
                            path: "GitBud/Views/WorkspaceView.swift",
                            status: "added",
                            additions: 9,
                            deletions: 0,
                            changes: 9,
                            patch: "@@ -0,0 +1 @@\n+panel"
                        )
                    ],
                    inlineComments: [
                        GitHubPullRequestInlineComment(
                            id: 1001,
                            path: "GitBud/App/AppModel.swift",
                            body: "This state split is easier to test.",
                            authorLogin: "reviewer",
                            line: 12,
                            side: "RIGHT"
                        ),
                        GitHubPullRequestInlineComment(
                            id: 1002,
                            path: "GitBud/Views/WorkspaceView.swift",
                            body: "This panel now exposes the patch.",
                            authorLogin: "sil",
                            originalLine: 4,
                            side: "LEFT"
                        )
                    ]
                )
            },
            pullRequestInlineCommentReplier: { repositoryFullName, number, commentID, body, token in
                replyCapture.repositoryFullName = repositoryFullName
                replyCapture.number = number
                replyCapture.commentID = commentID
                replyCapture.body = body
                replyCapture.token = token
                return GitHubPullRequestInlineComment(
                    id: 1003,
                    path: "GitBud/Views/WorkspaceView.swift",
                    body: body,
                    authorLogin: "sil",
                    line: 5,
                    side: "RIGHT"
                )
            },
            pullRequestInlineCommentCreator: { repositoryFullName, number, draft, token in
                inlineCommentCapture.repositoryFullName = repositoryFullName
                inlineCommentCapture.number = number
                inlineCommentCapture.draft = draft
                inlineCommentCapture.token = token
                return GitHubPullRequestInlineComment(
                    id: 1004,
                    path: draft.path,
                    body: draft.body,
                    authorLogin: "sil",
                    line: draft.line,
                    side: draft.side
                )
            },
            pullRequestReviewSubmitter: { repositoryFullName, number, event, body, token in
                reviewCapture.repositoryFullName = repositoryFullName
                reviewCapture.number = number
                reviewCapture.event = event
                reviewCapture.body = body
                reviewCapture.token = token
                return GitHubPullRequestSubmittedReview(
                    id: 2001,
                    state: "APPROVED",
                    body: body,
                    authorLogin: "sil",
                    url: URL(string: "https://github.com/sil/gitbud/pull/88#pullrequestreview-2001")
                )
            }
        )

        model.providerRepositories = [providerRepo]
        model.selectProviderRepository(providerRepo)
        model.remoteAccessToken = "review-token"
        model.loadProviderPullRequests()
        await waitForPullRequestList(model)
        model.loadSelectedProviderPullRequestReviewSummary()
        await waitForPullRequestReviewSummary(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(capture.repositoryFullName, "sil/gitbud")
        XCTAssertEqual(capture.number, 88)
        XCTAssertEqual(capture.token, "review-token")
        XCTAssertEqual(model.selectedProviderPullRequestNumber, 88)
        XCTAssertEqual(model.providerPullRequestReviewSummary?.changedFiles, 4)
        XCTAssertEqual(model.providerPullRequestReviewSummary?.commitCount, 3)
        XCTAssertEqual(model.providerPullRequestReviewSummary?.approvals, 1)
        XCTAssertEqual(model.providerPullRequestReviewSummary?.mergeableState, "clean")
        XCTAssertEqual(model.providerPullRequestReviewSummary?.files.first?.path, "GitBud/App/AppModel.swift")
        XCTAssertEqual(model.providerPullRequestReviewSummary?.files.first?.additions, 18)
        XCTAssertEqual(model.selectedProviderPullRequestFilePath, "GitBud/App/AppModel.swift")
        XCTAssertEqual(model.selectedProviderPullRequestFile?.patch, "@@ -1 +1 @@\n-old\n+new")
        XCTAssertEqual(model.selectedProviderPullRequestFileComments.map(\.id), [1001])
        XCTAssertEqual(model.selectedProviderPullRequestFileComments.first?.body, "This state split is easier to test.")
        let workspaceFile = try XCTUnwrap(model.providerPullRequestReviewSummary?.files.last)
        model.selectProviderPullRequestFile(workspaceFile)
        XCTAssertEqual(model.selectedProviderPullRequestFilePath, "GitBud/Views/WorkspaceView.swift")
        XCTAssertEqual(model.selectedProviderPullRequestFile?.status, "added")
        XCTAssertEqual(model.selectedProviderPullRequestFile?.patch, "@@ -0,0 +1 @@\n+panel")
        XCTAssertEqual(model.selectedProviderPullRequestFileComments.map(\.id), [1002])
        model.providerInlineCommentDraft = "This new panel should guard empty summaries."
        model.providerInlineCommentLineText = "4"
        model.providerInlineCommentSide = "RIGHT"
        model.postProviderInlineComment()
        await waitForPullRequestInlineComment(model)
        XCTAssertEqual(inlineCommentCapture.repositoryFullName, "sil/gitbud")
        XCTAssertEqual(inlineCommentCapture.number, 88)
        XCTAssertEqual(inlineCommentCapture.draft?.body, "This new panel should guard empty summaries.")
        XCTAssertEqual(inlineCommentCapture.draft?.commitID, "abc123")
        XCTAssertEqual(inlineCommentCapture.draft?.path, "GitBud/Views/WorkspaceView.swift")
        XCTAssertEqual(inlineCommentCapture.draft?.line, 4)
        XCTAssertEqual(inlineCommentCapture.draft?.side, "RIGHT")
        XCTAssertEqual(inlineCommentCapture.token, "review-token")
        XCTAssertEqual(model.providerInlineCommentDraft, "")
        XCTAssertEqual(model.providerInlineCommentLineText, "")
        XCTAssertEqual(model.selectedProviderInlineCommentID, 1004)
        XCTAssertEqual(model.selectedProviderPullRequestFileComments.map(\.id), [1002, 1004])
        XCTAssertEqual(model.statusMessage, "Posted inline comment to pull request #88.")
        model.selectProviderInlineComment(try XCTUnwrap(model.selectedProviderPullRequestFileComments.first))
        model.providerInlineReplyDraft = "Fixed in the native review panel."
        model.postProviderInlineCommentReply()
        await waitForPullRequestInlineReply(model)
        XCTAssertEqual(replyCapture.repositoryFullName, "sil/gitbud")
        XCTAssertEqual(replyCapture.number, 88)
        XCTAssertEqual(replyCapture.commentID, 1002)
        XCTAssertEqual(replyCapture.body, "Fixed in the native review panel.")
        XCTAssertEqual(replyCapture.token, "review-token")
        XCTAssertEqual(model.providerInlineReplyDraft, "")
        XCTAssertEqual(model.selectedProviderInlineCommentID, 1003)
        XCTAssertEqual(model.selectedProviderPullRequestFileComments.map(\.id), [1002, 1004, 1003])
        XCTAssertEqual(model.statusMessage, "Posted reply to pull request #88.")
        model.providerReviewBody = "The rewritten branch is ready."
        model.submitProviderPullRequestReview(.approve)
        await waitForPullRequestReviewSubmission(model)
        XCTAssertEqual(reviewCapture.repositoryFullName, "sil/gitbud")
        XCTAssertEqual(reviewCapture.number, 88)
        XCTAssertEqual(reviewCapture.event, .approve)
        XCTAssertEqual(reviewCapture.body, "The rewritten branch is ready.")
        XCTAssertEqual(reviewCapture.token, "review-token")
        XCTAssertEqual(model.providerReviewBody, "")
        XCTAssertEqual(model.providerSubmittedReview?.id, 2001)
        XCTAssertEqual(model.providerSubmittedReview?.state, "APPROVED")
        XCTAssertEqual(model.statusMessage, "Submitted approval review for pull request #88.")
    }

    func testAppModelSubmitsCommentPullRequestReview() async throws {
        let providerRepo = GitHubRepo(
            name: "gitbud",
            fullName: "sil/gitbud",
            ownerLogin: "sil",
            cloneURL: URL(string: "https://github.com/sil/gitbud.git")!,
            defaultBranch: "main",
            isPrivate: false
        )
        let pullRequest = GitHubPullRequest(
            number: 89,
            title: "feat: review comment",
            url: URL(string: "https://github.com/sil/gitbud/pull/89")!,
            head: "feature/comment",
            base: "main",
            state: "open",
            isDraft: false
        )
        let capture = PullRequestReviewSubmitCapture()
        let model = AppModel(pullRequestReviewSubmitter: { repositoryFullName, number, event, body, token in
            capture.repositoryFullName = repositoryFullName
            capture.number = number
            capture.event = event
            capture.body = body
            capture.token = token
            return GitHubPullRequestSubmittedReview(
                id: 2002,
                state: "COMMENTED",
                body: body,
                authorLogin: "sil",
                url: URL(string: "https://github.com/sil/gitbud/pull/89#pullrequestreview-2002")
            )
        })

        model.providerRepositories = [providerRepo]
        model.selectProviderRepository(providerRepo)
        model.providerPullRequests = [pullRequest]
        model.selectedProviderPullRequestNumber = pullRequest.number
        model.remoteAccessToken = "review-token"
        model.providerReviewBody = "Leaving this as a general review note."
        model.submitProviderPullRequestReview(.comment)
        await waitForPullRequestReviewSubmission(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(capture.repositoryFullName, "sil/gitbud")
        XCTAssertEqual(capture.number, 89)
        XCTAssertEqual(capture.event, .comment)
        XCTAssertEqual(capture.body, "Leaving this as a general review note.")
        XCTAssertEqual(capture.token, "review-token")
        XCTAssertEqual(model.providerReviewBody, "")
        XCTAssertEqual(model.providerSubmittedReview?.state, "COMMENTED")
        XCTAssertEqual(model.statusMessage, "Submitted comment review for pull request #89.")
    }

    func testAppModelSubmitsRequestChangesPullRequestReview() async throws {
        let providerRepo = GitHubRepo(
            name: "gitbud",
            fullName: "sil/gitbud",
            ownerLogin: "sil",
            cloneURL: URL(string: "https://github.com/sil/gitbud.git")!,
            defaultBranch: "main",
            isPrivate: false
        )
        let pullRequest = GitHubPullRequest(
            number: 90,
            title: "feat: request changes",
            url: URL(string: "https://github.com/sil/gitbud/pull/90")!,
            head: "feature/request-changes",
            base: "main",
            state: "open",
            isDraft: false
        )
        let capture = PullRequestReviewSubmitCapture()
        let model = AppModel(pullRequestReviewSubmitter: { repositoryFullName, number, event, body, token in
            capture.repositoryFullName = repositoryFullName
            capture.number = number
            capture.event = event
            capture.body = body
            capture.token = token
            return GitHubPullRequestSubmittedReview(
                id: 2003,
                state: "CHANGES_REQUESTED",
                body: body,
                authorLogin: "sil",
                url: URL(string: "https://github.com/sil/gitbud/pull/90#pullrequestreview-2003")
            )
        })

        model.providerRepositories = [providerRepo]
        model.selectProviderRepository(providerRepo)
        model.providerPullRequests = [pullRequest]
        model.selectedProviderPullRequestNumber = pullRequest.number
        model.remoteAccessToken = "review-token"
        model.providerReviewBody = "Please split the generated panel state before merge."
        model.submitProviderPullRequestReview(.requestChanges)
        await waitForPullRequestReviewSubmission(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(capture.repositoryFullName, "sil/gitbud")
        XCTAssertEqual(capture.number, 90)
        XCTAssertEqual(capture.event, .requestChanges)
        XCTAssertEqual(capture.body, "Please split the generated panel state before merge.")
        XCTAssertEqual(capture.token, "review-token")
        XCTAssertEqual(model.providerReviewBody, "")
        XCTAssertEqual(model.providerSubmittedReview?.state, "CHANGES_REQUESTED")
        XCTAssertEqual(model.statusMessage, "Submitted changes-requested review for pull request #90.")
    }

    func testAppModelSubmitsApprovalPullRequestReviewWithoutBody() async throws {
        let providerRepo = GitHubRepo(
            name: "gitbud",
            fullName: "sil/gitbud",
            ownerLogin: "sil",
            cloneURL: URL(string: "https://github.com/sil/gitbud.git")!,
            defaultBranch: "main",
            isPrivate: false
        )
        let pullRequest = GitHubPullRequest(
            number: 92,
            title: "feat: approve clean rewrite",
            url: URL(string: "https://github.com/sil/gitbud/pull/92")!,
            head: "feature/approve",
            base: "main",
            state: "open",
            isDraft: false
        )
        let capture = PullRequestReviewSubmitCapture()
        let model = AppModel(pullRequestReviewSubmitter: { repositoryFullName, number, event, body, token in
            capture.repositoryFullName = repositoryFullName
            capture.number = number
            capture.event = event
            capture.body = body
            capture.token = token
            return GitHubPullRequestSubmittedReview(
                id: 2005,
                state: "APPROVED",
                body: body,
                authorLogin: "sil",
                url: URL(string: "https://github.com/sil/gitbud/pull/92#pullrequestreview-2005")
            )
        })

        model.providerRepositories = [providerRepo]
        model.selectProviderRepository(providerRepo)
        model.providerPullRequests = [pullRequest]
        model.selectedProviderPullRequestNumber = pullRequest.number
        model.remoteAccessToken = "review-token"
        model.providerReviewBody = "   "
        model.submitProviderPullRequestReview(.approve)
        await waitForPullRequestReviewSubmission(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(capture.repositoryFullName, "sil/gitbud")
        XCTAssertEqual(capture.number, 92)
        XCTAssertEqual(capture.event, .approve)
        XCTAssertEqual(capture.body, "")
        XCTAssertEqual(capture.token, "review-token")
        XCTAssertEqual(model.providerReviewBody, "")
        XCTAssertEqual(model.providerSubmittedReview?.state, "APPROVED")
        XCTAssertEqual(model.statusMessage, "Submitted approval review for pull request #92.")
    }

    func testAppModelRequiresReviewBodyForCommentOrRequestChangesReview() {
        let providerRepo = GitHubRepo(
            name: "gitbud",
            fullName: "sil/gitbud",
            ownerLogin: "sil",
            cloneURL: URL(string: "https://github.com/sil/gitbud.git")!,
            defaultBranch: "main",
            isPrivate: false
        )
        let pullRequest = GitHubPullRequest(
            number: 91,
            title: "feat: review guard",
            url: URL(string: "https://github.com/sil/gitbud/pull/91")!,
            head: "feature/review-guard",
            base: "main",
            state: "open",
            isDraft: false
        )
        let capture = PullRequestReviewSubmitCapture()
        let model = AppModel(pullRequestReviewSubmitter: { repositoryFullName, number, event, body, token in
            capture.repositoryFullName = repositoryFullName
            capture.number = number
            capture.event = event
            capture.body = body
            capture.token = token
            return GitHubPullRequestSubmittedReview(
                id: 2004,
                state: event.rawValue,
                body: body,
                authorLogin: "sil",
                url: URL(string: "https://github.com/sil/gitbud/pull/91#pullrequestreview-2004")
            )
        })

        model.providerRepositories = [providerRepo]
        model.selectProviderRepository(providerRepo)
        model.providerPullRequests = [pullRequest]
        model.selectedProviderPullRequestNumber = pullRequest.number
        model.remoteAccessToken = "review-token"
        model.providerReviewBody = "   "
        model.submitProviderPullRequestReview(.comment)

        XCTAssertFalse(model.isSubmittingPullRequestReview)
        XCTAssertNil(capture.event)
        XCTAssertEqual(model.statusMessage, "Write a review message before commenting or requesting changes.")

        model.submitProviderPullRequestReview(.requestChanges)

        XCTAssertFalse(model.isSubmittingPullRequestReview)
        XCTAssertNil(capture.event)
        XCTAssertEqual(model.statusMessage, "Write a review message before commenting or requesting changes.")
    }

    func testAppModelSelectingProviderPullRequestClearsStaleReviewState() {
        let firstPullRequest = GitHubPullRequest(
            number: 101,
            title: "feat: first review",
            url: URL(string: "https://github.com/sil/gitbud/pull/101")!,
            head: "feature/first",
            headSHA: "first-head",
            base: "main"
        )
        let secondPullRequest = GitHubPullRequest(
            number: 102,
            title: "feat: second review",
            url: URL(string: "https://github.com/sil/gitbud/pull/102")!,
            head: "feature/second",
            headSHA: "second-head",
            base: "main"
        )
        let file = GitHubPullRequestFile(path: "First.swift", status: "modified", additions: 2, deletions: 1, changes: 3)
        let model = AppModel()

        model.providerPullRequests = [firstPullRequest, secondPullRequest]
        model.selectedProviderPullRequestNumber = firstPullRequest.number
        model.providerPullRequestReviewSummary = GitHubPullRequestReviewSummary(
            pullRequest: firstPullRequest,
            additions: 2,
            deletions: 1,
            changedFiles: 1,
            commitCount: 1,
            issueComments: 0,
            reviewComments: 1,
            mergeable: true,
            mergeableState: "clean",
            approvals: 0,
            requestedChanges: 0,
            reviewCommentThreads: 1,
            files: [file],
            inlineComments: [
                GitHubPullRequestInlineComment(id: 1011, path: "First.swift", body: "stale", authorLogin: "reviewer", line: 1, side: "RIGHT")
            ]
        )
        model.selectedProviderPullRequestFilePath = "First.swift"
        model.selectedProviderInlineCommentID = 1011
        model.providerInlineCommentDraft = "Do not keep this comment."
        model.providerInlineCommentLineText = "1"
        model.providerInlineReplyDraft = "Do not keep this reply."
        model.providerReviewBody = "Do not keep this review."
        model.providerSubmittedReview = GitHubPullRequestSubmittedReview(id: 1012, state: "APPROVED", body: "stale", authorLogin: "sil")

        model.selectProviderPullRequest(secondPullRequest)

        XCTAssertEqual(model.selectedProviderPullRequestNumber, secondPullRequest.number)
        XCTAssertNil(model.providerPullRequestReviewSummary)
        XCTAssertNil(model.selectedProviderPullRequestFilePath)
        XCTAssertNil(model.selectedProviderInlineCommentID)
        XCTAssertEqual(model.providerInlineCommentDraft, "")
        XCTAssertEqual(model.providerInlineCommentLineText, "")
        XCTAssertEqual(model.providerInlineReplyDraft, "")
        XCTAssertEqual(model.providerReviewBody, "")
        XCTAssertNil(model.providerSubmittedReview)
    }

    func testAppModelRequiresValidInlineCommentLineBeforePostingReviewComment() {
        let providerRepo = GitHubRepo(
            name: "gitbud",
            fullName: "sil/gitbud",
            ownerLogin: "sil",
            cloneURL: URL(string: "https://github.com/sil/gitbud.git")!,
            defaultBranch: "main",
            isPrivate: false
        )
        let pullRequest = GitHubPullRequest(
            number: 92,
            title: "feat: inline comment guard",
            url: URL(string: "https://github.com/sil/gitbud/pull/92")!,
            head: "feature/inline-comment",
            headSHA: "head-92",
            base: "main",
            state: "open",
            isDraft: false
        )
        let file = GitHubPullRequestFile(
            path: "GitBud/App/AppModel.swift",
            status: "modified",
            additions: 4,
            deletions: 1,
            changes: 5,
            patch: "@@ -1 +1 @@\n-old\n+new"
        )
        let capture = PullRequestInlineCommentCreateCapture()
        let model = AppModel(pullRequestInlineCommentCreator: { repositoryFullName, number, draft, token in
            capture.repositoryFullName = repositoryFullName
            capture.number = number
            capture.draft = draft
            capture.token = token
            return GitHubPullRequestInlineComment(
                id: 9201,
                path: draft.path,
                body: draft.body,
                authorLogin: "sil",
                line: draft.line,
                side: draft.side
            )
        })

        model.providerRepositories = [providerRepo]
        model.selectProviderRepository(providerRepo)
        model.providerPullRequests = [pullRequest]
        model.selectedProviderPullRequestNumber = pullRequest.number
        model.providerPullRequestReviewSummary = GitHubPullRequestReviewSummary(
            pullRequest: pullRequest,
            additions: 4,
            deletions: 1,
            changedFiles: 1,
            commitCount: 1,
            issueComments: 0,
            reviewComments: 0,
            mergeable: true,
            mergeableState: "clean",
            approvals: 0,
            requestedChanges: 0,
            reviewCommentThreads: 0,
            files: [file]
        )
        model.selectedProviderPullRequestFilePath = file.path
        model.remoteAccessToken = "review-token"
        model.providerInlineCommentDraft = "Please keep this guard strict."
        model.providerInlineCommentLineText = "not-a-line"
        model.postProviderInlineComment()

        XCTAssertFalse(model.isPostingPullRequestInlineComment)
        XCTAssertNil(capture.draft)
        XCTAssertEqual(model.providerInlineCommentDraft, "Please keep this guard strict.")
        XCTAssertEqual(model.providerInlineCommentLineText, "not-a-line")
        XCTAssertEqual(model.statusMessage, "Enter a changed-file line number before posting an inline comment.")
    }

    func testAppModelFetchRemoteUpdatesRemoteBranchesOnGit() async throws {
        let remote = tmp.appendingPathComponent("fetch-remote.git")
        try require(["init", "--bare", remote.path], in: tmp)
        let source = tmp.appendingPathComponent("fetch-source")
        let repo = tmp.appendingPathComponent("fetch-repo")
        try require(["clone", remote.path, source.path], in: tmp)
        try configureIdentity(source, name: "Fetch Source")
        try write("base\n", to: source, "base.txt")
        try commit("base", repo: source)
        try require(["push", "-u", "origin", "HEAD"], in: source)
        try require(["clone", remote.path, repo.path], in: tmp)
        try configureIdentity(repo, name: "Fetch Repo")

        let model = AppModel()
        await model.openRepository(repo)
        XCTAssertFalse(model.branches.contains { $0.shortName == "origin/feature/fetch" })

        try require(["switch", "-c", "feature/fetch"], in: source)
        try write("feature\n", to: source, "feature.txt")
        try commit("feature fetch", repo: source)
        try require(["push", "-u", "origin", "HEAD"], in: source)

        model.fetchRemote()
        await waitForRemoteSync(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.branches.contains { $0.shortName == "origin/feature/fetch" && $0.kind == .remote })
    }

    func testAppModelFetchRemotePreservesGitFailure() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        model.fetchRemote()
        await waitForRemoteSync(model)

        XCTAssertEqual(model.statusMessage, "Fetch needs attention.")
        XCTAssertTrue(model.errorMessage?.contains("git fetch failed") == true)
        XCTAssertEqual(model.commits.first?.subject, "base")
    }

    func testAppModelAddsAndRemovesRemoteOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let remote = tmp.appendingPathComponent("managed-extra.git")
        try require(["init", "--bare", remote.path], in: tmp)

        let model = AppModel()
        await model.openRepository(repo)
        XCTAssertTrue(model.remotes.isEmpty)

        model.newRemoteName = "backup"
        model.newRemoteURLString = remote.path
        model.addRemote()
        await waitForRemoteOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Added remote backup.")
        XCTAssertEqual(model.selectedRemoteName, "backup")
        XCTAssertEqual(model.selectedRemote?.fetchURL, remote.path)
        XCTAssertEqual(
            try require(["remote", "get-url", "backup"], in: repo).standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines),
            remote.path
        )

        model.removeSelectedRemote()
        await waitForRemoteOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Removed remote backup.")
        XCTAssertTrue(model.remotes.isEmpty)
        XCTAssertFalse(try runner.run(["remote", "get-url", "backup"], in: repo).succeeded)
    }

    func testAppModelCheckoutRemoteBranchCreatesLocalTrackingBranchOnGit() async throws {
        let remote = tmp.appendingPathComponent("tracking-remote.git")
        try require(["init", "--bare", remote.path], in: tmp)
        let source = tmp.appendingPathComponent("tracking-source")
        let repo = tmp.appendingPathComponent("tracking-repo")
        try require(["clone", remote.path, source.path], in: tmp)
        try configureIdentity(source, name: "Tracking Source")
        try write("base\n", to: source, "base.txt")
        try commit("base", repo: source)
        try require(["push", "-u", "origin", "HEAD"], in: source)
        try require(["switch", "-c", "feature/tracking"], in: source)
        try write("feature\n", to: source, "feature.txt")
        try commit("feature tracking", repo: source)
        try require(["push", "-u", "origin", "HEAD"], in: source)
        try require(["clone", remote.path, repo.path], in: tmp)
        try configureIdentity(repo, name: "Tracking Repo")

        let model = AppModel()
        await model.openRepository(repo)
        let remoteBranch = try XCTUnwrap(model.branches.first { $0.shortName == "origin/feature/tracking" && $0.kind == .remote })
        model.checkoutBranch(remoteBranch)
        await waitForBranchChange(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.branches.contains { $0.shortName == "feature/tracking" && $0.kind == .local && $0.isCurrent })
        XCTAssertEqual(try require(["branch", "--show-current"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "feature/tracking")
        XCTAssertEqual(try require(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "origin/feature/tracking")
        XCTAssertEqual(try read(repo, "feature.txt"), "feature\n")
    }

    func testAppModelPullRebaseLandsRemoteAndLocalCommitsOnGit() async throws {
        let (source, repo) = try makeSyncedRemotePair(prefix: "pull-clean")

        try write("remote\n", to: source, "remote.txt")
        try commit("remote change", repo: source)
        try require(["push"], in: source)

        try write("local\n", to: repo, "local.txt")
        try commit("local change", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        model.pullCurrentBranchWithRebase()
        await waitForRemoteSync(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(Array(try logSubjects(repo).prefix(3)), ["local change", "remote change", "base"])
        XCTAssertEqual(try read(repo, "remote.txt"), "remote\n")
        XCTAssertEqual(try read(repo, "local.txt"), "local\n")
        XCTAssertTrue(model.conflicts.isEmpty)
    }

    func testAppModelPullRebaseSurfacesRemoteConflictsWithClearLabels() async throws {
        let (source, repo) = try makeSyncedRemotePair(prefix: "pull-conflict")

        try write("local\n", to: repo, "base.txt")
        try commit("local edit", repo: repo)

        try write("remote\n", to: source, "base.txt")
        try commit("remote edit", repo: source)
        try require(["push"], in: source)

        let model = AppModel()
        await model.openRepository(repo)
        model.pullCurrentBranchWithRebase()
        await waitForRemoteSync(model)

        XCTAssertNil(model.errorMessage)
        let conflict = try XCTUnwrap(model.conflicts.first)
        XCTAssertEqual(conflict.path, "base.txt")
        XCTAssertEqual(conflict.sections.map(\.side.rawValue), ["Your change", "REmote change"])
        model.conflictDrafts[conflict.path] = "manual sync resolution\n"
        model.resolveConflictWithDraft(conflict)
        await waitForRewrite(model)
        model.continueRebase()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try read(repo, "base.txt"), "manual sync resolution\n")
        XCTAssertTrue(model.conflicts.isEmpty)
    }

    func testAppModelPullRebasePreservesGitFailure() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        model.pullCurrentBranchWithRebase()
        await waitForRemoteSync(model)

        XCTAssertEqual(model.statusMessage, "Pull rebase needs attention.")
        XCTAssertTrue(model.errorMessage?.contains("git pull --rebase failed") == true)
        XCTAssertTrue(model.conflicts.isEmpty)
        XCTAssertEqual(try logSubjects(repo).first, "base")
    }

    func testAppModelPushCurrentBranchLandsOnRemote() async throws {
        let remote = tmp.appendingPathComponent("push-current-remote.git")
        try require(["init", "--bare", remote.path], in: tmp)
        let repo = tmp.appendingPathComponent("push-current-repo")
        try require(["clone", remote.path, repo.path], in: tmp)
        try configureIdentity(repo, name: "GitBud Push")
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try require(["push", "-u", "origin", "HEAD"], in: repo)
        let branch = try require(["branch", "--show-current"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try write("local\n", to: repo, "local.txt")
        try commit("local change", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        model.pushCurrentBranch()
        await waitForRemoteSync(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Pushed current branch.")
        let remoteSubject = try require(["--git-dir", remote.path, "log", "--format=%s", "-1", "refs/heads/\(branch)"], in: tmp).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(remoteSubject, "local change")
        XCTAssertEqual(model.branchSummary?.ahead, 0)
        XCTAssertEqual(model.branchSummary?.behind, 0)
    }

    func testAppModelPushCurrentBranchPreservesGitFailure() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        model.pushCurrentBranch()
        await waitForRemoteSync(model)

        XCTAssertEqual(model.statusMessage, "Push needs attention.")
        XCTAssertTrue(model.errorMessage?.contains("git push failed") == true)
        XCTAssertEqual(try logSubjects(repo).first, "base")
    }

    func testAppModelCreatesBranchFromSelectedCommitAndSwitchesBranchesOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let initialBranch = try require(["branch", "--show-current"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseCommit = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try write("main\n", to: repo, "main.txt")
        try commit("main work", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        XCTAssertTrue(model.branches.contains { $0.shortName == initialBranch && $0.isCurrent })
        model.focusedCommitID = baseCommit
        model.newBranchName = "feature/gitbud-branch"
        model.createBranchFromSelectedCommit()
        await waitForBranchChange(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.branches.contains { $0.shortName == "feature/gitbud-branch" && $0.isCurrent })
        XCTAssertEqual(try require(["branch", "--show-current"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "feature/gitbud-branch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("main.txt").path))

        let main = try XCTUnwrap(model.branches.first { $0.shortName == initialBranch })
        model.checkoutBranch(main)
        await waitForBranchChange(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.branches.contains { $0.shortName == initialBranch && $0.isCurrent })
        XCTAssertEqual(try read(repo, "main.txt"), "main\n")
    }

    func testAppModelCheckoutBranchRequiresCleanWorkingTree() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let initialBranch = try require(["branch", "--show-current"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(["switch", "-c", "feature/target"], in: repo)
        try write("feature\n", to: repo, "feature.txt")
        try commit("feature work", repo: repo)
        try require(["switch", initialBranch], in: repo)
        try write("dirty\n", to: repo, "dirty.txt")

        let model = AppModel()
        await model.openRepository(repo)
        let target = try XCTUnwrap(model.branches.first { $0.shortName == "feature/target" })
        model.checkoutBranch(target)
        await waitForBranchChange(model)

        XCTAssertEqual(model.errorMessage, "The working tree must be clean before rewriting history.")
        XCTAssertEqual(model.statusMessage, "Could not switch branch.")
        XCTAssertTrue(model.branches.contains { $0.shortName == initialBranch && $0.isCurrent })
        XCTAssertEqual(try require(["branch", "--show-current"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), initialBranch)
        XCTAssertEqual(try read(repo, "dirty.txt"), "dirty\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("feature.txt").path))
    }

    func testAppModelCreateBranchFromSelectedCommitRequiresCleanWorkingTree() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let initialBranch = try require(["branch", "--show-current"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseCommit = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try write("dirty\n", to: repo, "dirty.txt")

        let model = AppModel()
        await model.openRepository(repo)
        model.focusedCommitID = baseCommit
        model.newBranchName = "feature/dirty-create"
        model.createBranchFromSelectedCommit()
        await waitForBranchChange(model)

        XCTAssertEqual(model.errorMessage, "The working tree must be clean before rewriting history.")
        XCTAssertEqual(model.statusMessage, "Could not create branch.")
        XCTAssertEqual(model.newBranchName, "feature/dirty-create")
        XCTAssertTrue(model.branches.contains { $0.shortName == initialBranch && $0.isCurrent })
        XCTAssertFalse(model.branches.contains { $0.shortName == "feature/dirty-create" })
        XCTAssertEqual(try require(["branch", "--list", "feature/dirty-create"], in: repo).standardOutput, "")
        XCTAssertEqual(try read(repo, "dirty.txt"), "dirty\n")
    }

    func testAppModelRenamesAndDeletesSelectedLocalBranchOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try require(["branch", "feature/old"], in: repo)

        let model = AppModel()
        await model.openRepository(repo)
        let oldBranch = try XCTUnwrap(model.branches.first { $0.shortName == "feature/old" })
        model.selectBranchOperationTarget(oldBranch)
        model.renameBranchName = "feature/new"
        model.renameSelectedBranch()
        await waitForBranchOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.branches.contains { $0.shortName == "feature/old" })
        XCTAssertTrue(model.branches.contains { $0.shortName == "feature/new" })
        XCTAssertTrue(try require(["branch", "--list", "feature/new"], in: repo).standardOutput.contains("feature/new"))

        let newBranch = try XCTUnwrap(model.branches.first { $0.shortName == "feature/new" })
        model.selectBranchOperationTarget(newBranch)
        model.deleteSelectedBranch()
        await waitForBranchOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.branches.contains { $0.shortName == "feature/new" })
        XCTAssertEqual(try require(["branch", "--list", "feature/new"], in: repo).standardOutput, "")
    }

    func testAppModelRenameSelectedBranchRequiresCleanWorkingTree() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try require(["branch", "feature/old"], in: repo)
        try write("dirty\n", to: repo, "dirty.txt")

        let model = AppModel()
        await model.openRepository(repo)
        let oldBranch = try XCTUnwrap(model.branches.first { $0.shortName == "feature/old" })
        model.selectBranchOperationTarget(oldBranch)
        model.renameBranchName = "feature/new"
        model.renameSelectedBranch()
        await waitForBranchOperation(model)

        XCTAssertEqual(model.errorMessage, "The working tree must be clean before rewriting history.")
        XCTAssertEqual(model.statusMessage, "Branch action needs attention.")
        XCTAssertTrue(model.branches.contains { $0.shortName == "feature/old" })
        XCTAssertFalse(model.branches.contains { $0.shortName == "feature/new" })
        XCTAssertTrue(try require(["branch", "--list", "feature/old"], in: repo).standardOutput.contains("feature/old"))
        XCTAssertEqual(try require(["branch", "--list", "feature/new"], in: repo).standardOutput, "")
        XCTAssertEqual(try read(repo, "dirty.txt"), "dirty\n")
    }

    func testAppModelCreatesAndDeletesTagOnSelectedCommit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let base = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try write("later\n", to: repo, "later.txt")
        try commit("later", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        let baseNode = try XCTUnwrap(model.commits.first { $0.id == base })
        model.selectCommit(baseNode)
        model.newTagName = "v1.0.0"
        model.createTagFromSelectedCommit()
        await waitForTagOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.tags.contains { $0.name == "v1.0.0" && $0.commitID == base })
        XCTAssertEqual(model.newTagName, "")
        XCTAssertEqual(try require(["tag", "--points-at", base], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "v1.0.0")

        model.selectedTagName = "v1.0.0"
        model.deleteSelectedTag()
        await waitForTagOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.tags.contains { $0.name == "v1.0.0" })
        XCTAssertEqual(try require(["tag", "--list", "v1.0.0"], in: repo).standardOutput, "")
    }

    func testAppModelCreateTagFromSelectedCommitRequiresCleanWorkingTree() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let base = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try write("dirty\n", to: repo, "dirty.txt")

        let model = AppModel()
        await model.openRepository(repo)
        let baseNode = try XCTUnwrap(model.commits.first { $0.id == base })
        model.selectCommit(baseNode)
        model.newTagName = "v1.0.0"
        model.createTagFromSelectedCommit()
        await waitForTagOperation(model)

        XCTAssertEqual(model.errorMessage, "The working tree must be clean before rewriting history.")
        XCTAssertEqual(model.statusMessage, "Tag action needs attention.")
        XCTAssertFalse(model.tags.contains { $0.name == "v1.0.0" })
        XCTAssertEqual(model.newTagName, "v1.0.0")
        XCTAssertEqual(try require(["tag", "--list", "v1.0.0"], in: repo).standardOutput, "")
        XCTAssertEqual(try read(repo, "dirty.txt"), "dirty\n")
    }

    func testAppModelBranchFlowExplainsSelectedMergeRebaseTarget() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let initialBranch = try require(["branch", "--show-current"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(["switch", "-c", "feature/flow"], in: repo)
        try write("feature 1\n", to: repo, "feature-one.txt")
        try commit("feature one", repo: repo)
        try write("feature 2\n", to: repo, "feature-two.txt")
        try commit("feature two", repo: repo)
        try require(["switch", initialBranch], in: repo)
        try write("main 1\n", to: repo, "main-one.txt")
        try commit("main one", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        let target = try XCTUnwrap(model.branches.first { $0.shortName == "feature/flow" })
        model.selectBranchOperationTarget(target)
        await waitForBranchFlow(model)

        let flow = try XCTUnwrap(model.branchFlow)
        XCTAssertEqual(flow.currentBranch, initialBranch)
        XCTAssertEqual(flow.targetBranch, "feature/flow")
        XCTAssertEqual(flow.mergeBaseSubject, "base")
        XCTAssertEqual(flow.currentOnlyCommits.map(\.subject), ["main one"])
        XCTAssertEqual(flow.targetOnlyCommits.map(\.subject), ["feature one", "feature two"])
        XCTAssertEqual(flow.changedFiles.map(\.path).sorted(), ["feature-one.txt", "feature-two.txt", "main-one.txt"])
        XCTAssertTrue(flow.changedFiles.contains { $0.path == "feature-one.txt" && $0.status == "A" })
        XCTAssertTrue(flow.changedFiles.contains { $0.path == "feature-two.txt" && $0.status == "A" })
        XCTAssertTrue(flow.changedFiles.contains { $0.path == "main-one.txt" && $0.status == "D" })
    }

    func testAppModelMergesSelectedBranchIntoCurrentOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let initialBranch = try require(["branch", "--show-current"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(["switch", "-c", "feature/merge"], in: repo)
        try write("feature\n", to: repo, "feature.txt")
        try commit("feature work", repo: repo)
        try require(["switch", initialBranch], in: repo)
        try write("main\n", to: repo, "main.txt")
        try commit("main work", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        model.selectedBranchOperationTargetName = "feature/merge"
        model.mergeSelectedBranchIntoCurrent()
        await waitForBranchOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.conflicts.isEmpty)
        XCTAssertEqual(try read(repo, "feature.txt"), "feature\n")
        XCTAssertEqual(try read(repo, "main.txt"), "main\n")
        XCTAssertEqual(try logSubjects(repo).first, "Merge branch 'feature/merge'")
    }

    func testAppModelMergeSelectedBranchSurfacesConflictAndContinuesOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "story.txt")
        try commit("base", repo: repo)
        let initialBranch = try require(["branch", "--show-current"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(["switch", "-c", "feature/merge-continue"], in: repo)
        try write("feature\n", to: repo, "story.txt")
        try commit("feature edit", repo: repo)
        let featureHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(["switch", initialBranch], in: repo)
        try write("main\n", to: repo, "story.txt")
        try commit("main edit", repo: repo)
        let mainHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let model = AppModel()
        await model.openRepository(repo)
        model.selectedBranchOperationTargetName = "feature/merge-continue"
        model.mergeSelectedBranchIntoCurrent()
        await waitForBranchOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Merge has conflicts.")
        XCTAssertEqual(model.activeConflictMode, .merge)
        let conflict = try XCTUnwrap(model.conflicts.first)
        XCTAssertEqual(conflict.path, "story.txt")
        XCTAssertEqual(conflict.sections.map(\.side.rawValue), ["Your change", "REmote change"])

        model.conflictDrafts[conflict.path] = "merged story\n"
        model.resolveConflictWithDraft(conflict)
        await waitForRewrite(model)
        model.continueRebase()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Continued merge.")
        XCTAssertTrue(model.conflicts.isEmpty)
        XCTAssertEqual(try require(["branch", "--show-current"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), initialBranch)
        XCTAssertEqual(try read(repo, "story.txt"), "merged story\n")
        XCTAssertEqual(try logSubjects(repo).first, "Merge branch 'feature/merge-continue'")
        let parents = try require(["rev-list", "--parents", "-n", "1", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .map(String.init)
        XCTAssertEqual(parents.count, 3)
        XCTAssertEqual(parents[1], mainHead)
        XCTAssertEqual(parents[2], featureHead)
        XCTAssertFalse(try runner.run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: repo).succeeded)
    }

    func testAppModelAbortSelectedBranchMergeRestoresPreMergeStateOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "story.txt")
        try commit("base", repo: repo)
        let initialBranch = try require(["branch", "--show-current"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let initialHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(["switch", "-c", "feature/merge-conflict"], in: repo)
        try write("feature\n", to: repo, "story.txt")
        try commit("feature edit", repo: repo)
        try require(["switch", initialBranch], in: repo)
        try write("main\n", to: repo, "story.txt")
        try commit("main edit", repo: repo)
        let preMergeHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let model = AppModel()
        await model.openRepository(repo)
        model.selectedBranchOperationTargetName = "feature/merge-conflict"
        model.mergeSelectedBranchIntoCurrent()
        await waitForBranchOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Merge has conflicts.")
        XCTAssertEqual(model.activeConflictMode, .merge)
        XCTAssertEqual(model.conflicts.first?.path, "story.txt")
        XCTAssertEqual(model.conflicts.first?.sections.map(\.side.rawValue), ["Your change", "REmote change"])

        model.abortRebase()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Aborted merge.")
        XCTAssertTrue(model.conflicts.isEmpty)
        XCTAssertEqual(try require(["branch", "--show-current"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), initialBranch)
        XCTAssertEqual(try require(["rev-parse", "HEAD"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), preMergeHead)
        XCTAssertNotEqual(preMergeHead, initialHead)
        XCTAssertEqual(try read(repo, "story.txt"), "main\n")
        XCTAssertFalse(try runner.run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: repo).succeeded)
    }

    func testAppModelRebaseCurrentBranchOntoSelectedBranchSurfacesConflictAndResolvesOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "story.txt")
        try commit("base", repo: repo)
        let initialBranch = try require(["branch", "--show-current"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(["switch", "-c", "feature/rebase"], in: repo)
        try write("local\n", to: repo, "story.txt")
        try commit("feature edit", repo: repo)
        try require(["switch", initialBranch], in: repo)
        try write("remote\n", to: repo, "story.txt")
        try commit("main edit", repo: repo)
        try require(["switch", "feature/rebase"], in: repo)

        let model = AppModel()
        await model.openRepository(repo)
        model.selectedBranchOperationTargetName = initialBranch
        model.rebaseCurrentBranchOntoSelectedBranch()
        await waitForBranchOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.activeConflictMode, .rebase)
        XCTAssertEqual(model.conflicts.first?.path, "story.txt")
        XCTAssertEqual(model.conflicts.first?.sections.map(\.side.rawValue), ["Your change", "REmote change"])

        let conflict = try XCTUnwrap(model.conflicts.first)
        model.resolveConflict(conflict, taking: .yourChange)
        await waitForRewrite(model)
        model.continueRebase()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.conflicts.isEmpty)
        XCTAssertEqual(try read(repo, "story.txt"), "local\n")
        XCTAssertEqual(try require(["branch", "--show-current"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "feature/rebase")
    }

    func testAppModelAbortSelectedBranchRebaseRestoresFeatureStateOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "story.txt")
        try commit("base", repo: repo)
        let initialBranch = try require(["branch", "--show-current"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(["switch", "-c", "feature/rebase-abort"], in: repo)
        try write("local\n", to: repo, "story.txt")
        try commit("feature edit", repo: repo)
        let preRebaseHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(["switch", initialBranch], in: repo)
        try write("remote\n", to: repo, "story.txt")
        try commit("main edit", repo: repo)
        try require(["switch", "feature/rebase-abort"], in: repo)

        let model = AppModel()
        await model.openRepository(repo)
        model.selectedBranchOperationTargetName = initialBranch
        model.rebaseCurrentBranchOntoSelectedBranch()
        await waitForBranchOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Rebase has conflicts.")
        XCTAssertEqual(model.activeConflictMode, .rebase)
        XCTAssertEqual(model.conflicts.first?.path, "story.txt")
        XCTAssertEqual(model.conflicts.first?.sections.map(\.side.rawValue), ["Your change", "REmote change"])

        model.abortRebase()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Aborted rebase.")
        XCTAssertTrue(model.conflicts.isEmpty)
        XCTAssertEqual(try require(["branch", "--show-current"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "feature/rebase-abort")
        XCTAssertEqual(try require(["rev-parse", "HEAD"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), preRebaseHead)
        XCTAssertEqual(try read(repo, "story.txt"), "local\n")
        XCTAssertFalse(try runner.run(["rev-parse", "-q", "--verify", "REBASE_HEAD"], in: repo).succeeded)
    }

    func testAppModelStagesUnstagesAndDiscardsWorktreeChangesOnGit() async throws {
        let repo = try makeRepo()
        try write("one\n", to: repo, "story.txt")
        try commit("seed", repo: repo)
        try write("two\n", to: repo, "story.txt")

        let model = AppModel()
        await model.openRepository(repo)

        XCTAssertEqual(model.worktreeFiles.first?.path, "story.txt")
        XCTAssertEqual(model.worktreeFiles.first?.workingTreeStatus, "M")
        model.selectedWorktreePaths = ["story.txt"]
        model.stageSelectedWorktreePaths()
        await waitForWorktreeUpdate(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.worktreeFiles.first?.indexStatus, "M")
        XCTAssertEqual(model.worktreeFiles.first?.workingTreeStatus, " ")
        XCTAssertEqual(try require(["diff", "--cached", "--name-only"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "story.txt")

        model.selectedWorktreePaths = ["story.txt"]
        model.unstageSelectedWorktreePaths()
        await waitForWorktreeUpdate(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.worktreeFiles.first?.indexStatus, " ")
        XCTAssertEqual(model.worktreeFiles.first?.workingTreeStatus, "M")
        XCTAssertTrue(try require(["diff", "--cached", "--quiet"], in: repo).succeeded)

        model.selectedWorktreePaths = ["story.txt"]
        model.discardSelectedWorktreePaths()
        await waitForWorktreeUpdate(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.worktreeFiles.isEmpty)
        XCTAssertEqual(try read(repo, "story.txt"), "one\n")
    }

    func testAppModelAddsAndRemovesLinkedWorktreeOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let linkedPath = tmp.appendingPathComponent("linked-feature").path
        let normalizedRepoPath = repo.standardizedFileURL.path
        let normalizedLinkedPath = URL(fileURLWithPath: linkedPath).standardizedFileURL.path

        let model = AppModel()
        await model.openRepository(repo)
        XCTAssertTrue(model.linkedWorktrees.contains { $0.path == normalizedRepoPath && $0.isCurrent })

        model.newLinkedWorktreePath = linkedPath
        model.newLinkedWorktreeBranch = "feature/worktree"
        model.addLinkedWorktree()
        await waitForLinkedWorktreeOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Created linked worktree feature/worktree.")
        let linked = try XCTUnwrap(model.linkedWorktrees.first { $0.path == normalizedLinkedPath })
        XCTAssertEqual(linked.branch, "feature/worktree")
        XCTAssertFalse(linked.isCurrent)
        XCTAssertEqual(model.selectedLinkedWorktreePath, normalizedLinkedPath)
        XCTAssertEqual(try read(URL(fileURLWithPath: linkedPath), "base.txt"), "base\n")

        model.removeSelectedLinkedWorktree()
        await waitForLinkedWorktreeOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Removed linked worktree.")
        XCTAssertFalse(model.linkedWorktrees.contains { $0.path == normalizedLinkedPath })
        XCTAssertFalse(FileManager.default.fileExists(atPath: linkedPath))
    }

    func testAppModelAddLinkedWorktreePreservesGitFailure() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let linkedPath = tmp.appendingPathComponent("linked-invalid").path

        let model = AppModel()
        await model.openRepository(repo)
        model.newLinkedWorktreePath = linkedPath
        model.newLinkedWorktreeBranch = "bad..branch"
        model.addLinkedWorktree()
        await waitForLinkedWorktreeOperation(model)

        XCTAssertEqual(model.statusMessage, "Linked worktree action needs attention.")
        XCTAssertEqual(model.errorMessage, "bad..branch is not a valid branch name.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: linkedPath))
        XCTAssertTrue(model.linkedWorktrees.contains { $0.path == repo.standardizedFileURL.path && $0.isCurrent })
    }

    func testAppModelListsAndUpdatesSelectedSubmoduleOnGit() async throws {
        let submoduleRepo = tmp.appendingPathComponent("submodule-source")
        try require(["init", submoduleRepo.path], in: tmp)
        try configureIdentity(submoduleRepo, name: "GitBud Submodule")
        try write("submodule\n", to: submoduleRepo, "module.txt")
        try commit("submodule seed", repo: submoduleRepo)

        let repo = try makeRepo()
        try require(["-c", "protocol.file.allow=always", "submodule", "add", submoduleRepo.path, "Vendor/Sub"], in: repo)
        try commit("add submodule", repo: repo)
        try require(["submodule", "deinit", "-f", "Vendor/Sub"], in: repo)

        let model = AppModel()
        await model.openRepository(repo)

        let submodule = try XCTUnwrap(model.submodules.first)
        XCTAssertEqual(submodule.path, "Vendor/Sub")
        XCTAssertEqual(submodule.state, .uninitialized)
        XCTAssertEqual(model.selectedSubmodulePath, "Vendor/Sub")

        model.updateSelectedSubmodule()
        await waitForSubmoduleOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Updated Vendor/Sub.")
        XCTAssertEqual(model.submodules.first?.state, .initialized)
        XCTAssertEqual(try read(repo.appendingPathComponent("Vendor/Sub"), "module.txt"), "submodule\n")
    }

    func testAppModelUpdatesAllSubmodulesOnGit() async throws {
        let firstSubmoduleRepo = tmp.appendingPathComponent("submodule-source-one")
        try require(["init", firstSubmoduleRepo.path], in: tmp)
        try configureIdentity(firstSubmoduleRepo, name: "GitBud Submodule One")
        try write("first submodule\n", to: firstSubmoduleRepo, "module.txt")
        try commit("first submodule seed", repo: firstSubmoduleRepo)

        let secondSubmoduleRepo = tmp.appendingPathComponent("submodule-source-two")
        try require(["init", secondSubmoduleRepo.path], in: tmp)
        try configureIdentity(secondSubmoduleRepo, name: "GitBud Submodule Two")
        try write("second submodule\n", to: secondSubmoduleRepo, "module.txt")
        try commit("second submodule seed", repo: secondSubmoduleRepo)

        let repo = try makeRepo()
        try require(["-c", "protocol.file.allow=always", "submodule", "add", firstSubmoduleRepo.path, "Vendor/One"], in: repo)
        try require(["-c", "protocol.file.allow=always", "submodule", "add", secondSubmoduleRepo.path, "Vendor/Two"], in: repo)
        try commit("add submodules", repo: repo)
        try require(["submodule", "deinit", "-f", "Vendor/One"], in: repo)
        try require(["submodule", "deinit", "-f", "Vendor/Two"], in: repo)

        let model = AppModel()
        await model.openRepository(repo)

        XCTAssertEqual(model.submodules.map(\.path), ["Vendor/One", "Vendor/Two"])
        XCTAssertTrue(model.submodules.allSatisfy { $0.state == .uninitialized })

        model.updateAllSubmodules()
        await waitForSubmoduleOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Updated submodules.")
        XCTAssertEqual(model.submodules.map(\.path), ["Vendor/One", "Vendor/Two"])
        XCTAssertTrue(model.submodules.allSatisfy { $0.state == .initialized })
        XCTAssertEqual(try read(repo.appendingPathComponent("Vendor/One"), "module.txt"), "first submodule\n")
        XCTAssertEqual(try read(repo.appendingPathComponent("Vendor/Two"), "module.txt"), "second submodule\n")
    }

    func testAppModelUpdateSelectedSubmodulePreservesGitFailure() async throws {
        let submoduleRepo = tmp.appendingPathComponent("missing-submodule-source")
        try require(["init", submoduleRepo.path], in: tmp)
        try configureIdentity(submoduleRepo, name: "GitBud Missing Submodule")
        try write("submodule\n", to: submoduleRepo, "module.txt")
        try commit("submodule seed", repo: submoduleRepo)

        let repo = try makeRepo()
        try require(["-c", "protocol.file.allow=always", "submodule", "add", submoduleRepo.path, "Vendor/Missing"], in: repo)
        try commit("add submodule", repo: repo)
        try require(["submodule", "deinit", "-f", "Vendor/Missing"], in: repo)

        let model = AppModel()
        await model.openRepository(repo)
        XCTAssertEqual(model.submodules.first?.path, "Vendor/Missing")
        let submodulePath = repo.appendingPathComponent("Vendor/Missing")
        if FileManager.default.fileExists(atPath: submodulePath.path) {
            try FileManager.default.removeItem(at: submodulePath)
        }
        try Data("blocking file\n".utf8).write(to: submodulePath)

        model.updateSelectedSubmodule()
        await waitForSubmoduleOperation(model)

        XCTAssertEqual(model.statusMessage, "Submodule action needs attention.")
        XCTAssertTrue(model.errorMessage?.contains("submodule update failed") == true)
        XCTAssertEqual(model.submodules.first?.path, "Vendor/Missing")
    }

    func testAppModelCommitsSelectedWorktreePathsOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("seed", repo: repo)
        try write("selected\n", to: repo, "selected.txt")
        try write("left alone\n", to: repo, "left-alone.txt")

        let model = AppModel()
        await model.openRepository(repo)
        model.selectedWorktreePaths = ["selected.txt"]
        model.worktreeCommitMessage = "feat: commit selected worktree path"
        model.commitSelectedWorktreePaths()
        await waitForWorktreeCommit(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try logSubjects(repo).first, "feat: commit selected worktree path")
        let committedFiles = try require(["show", "--format=", "--name-only", "HEAD"], in: repo).standardOutput
        XCTAssertTrue(committedFiles.split(separator: "\n").contains("selected.txt"))
        XCTAssertFalse(committedFiles.split(separator: "\n").contains("left-alone.txt"))
        XCTAssertEqual(model.worktreeCommitMessage, "")
        XCTAssertTrue(model.worktreeFiles.contains { $0.path == "left-alone.txt" && $0.displayStatus == "?" })
    }

    func testAppModelCommitSelectedWorktreePathsPreservesNothingToCommitFailure() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("seed", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        model.selectedWorktreePaths = ["base.txt"]
        model.worktreeCommitMessage = "feat: nothing to commit"
        model.commitSelectedWorktreePaths()
        await waitForWorktreeCommit(model)

        XCTAssertEqual(model.statusMessage, "Commit needs attention.")
        XCTAssertEqual(model.errorMessage, "Nothing to commit.")
        XCTAssertEqual(model.worktreeCommitMessage, "feat: nothing to commit")
        XCTAssertTrue(model.selectedWorktreePaths.isEmpty)
        XCTAssertEqual(try logSubjects(repo).first, "seed")
    }

    func testAppModelAmendsHeadWithSelectedWorktreePathsOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "selected.txt")
        try write("keep\n", to: repo, "left-alone.txt")
        try commit("feat: seed", repo: repo)
        try write("base\nselected amend\n", to: repo, "selected.txt")
        try write("new file\n", to: repo, "new.txt")
        try write("keep\nunselected\n", to: repo, "left-alone.txt")

        let model = AppModel()
        await model.openRepository(repo)
        model.selectedWorktreePaths = ["selected.txt", "new.txt"]
        model.amendHeadWithSelectedWorktreePaths()
        await waitForWorktreeCommit(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try logSubjects(repo).first, "feat: seed")
        XCTAssertEqual(try require(["show", "HEAD:selected.txt"], in: repo).standardOutput, "base\nselected amend\n")
        XCTAssertEqual(try require(["show", "HEAD:new.txt"], in: repo).standardOutput, "new file\n")
        XCTAssertEqual(try require(["show", "HEAD:left-alone.txt"], in: repo).standardOutput, "keep\n")
        XCTAssertTrue(model.selectedWorktreePaths.isEmpty)
        XCTAssertTrue(model.worktreeFiles.contains { $0.path == "left-alone.txt" && $0.workingTreeStatus == "M" })
        XCTAssertEqual(model.statusMessage, "Amended HEAD with selected changes.")
    }

    func testAppModelAmendHeadWithSelectedWorktreePathsPreservesNothingToCommitFailure() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "selected.txt")
        try commit("feat: seed", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        model.selectedWorktreePaths = ["missing.txt"]
        model.amendHeadWithSelectedWorktreePaths()
        await waitForWorktreeCommit(model)

        XCTAssertEqual(model.statusMessage, "Amend needs attention.")
        XCTAssertTrue(model.errorMessage?.contains("git commit --amend --only failed") == true)
        XCTAssertTrue(model.selectedWorktreePaths.isEmpty)
        XCTAssertEqual(try logSubjects(repo).first, "feat: seed")
    }

    func testAppModelDiscardsUntrackedPathWithoutTouchingTrackedEdits() async throws {
        let repo = try makeRepo()
        try write("one\n", to: repo, "story.txt")
        try commit("seed", repo: repo)
        try write("two\n", to: repo, "story.txt")
        try write("scratch\n", to: repo, "scratch.txt")

        let model = AppModel()
        await model.openRepository(repo)
        XCTAssertTrue(model.worktreeFiles.contains { $0.path == "story.txt" })
        XCTAssertTrue(model.worktreeFiles.contains { $0.path == "scratch.txt" && $0.displayStatus == "?" })

        model.selectedWorktreePaths = ["scratch.txt"]
        model.discardSelectedWorktreePaths()
        await waitForWorktreeUpdate(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("scratch.txt").path))
        XCTAssertEqual(try read(repo, "story.txt"), "two\n")
        XCTAssertTrue(model.worktreeFiles.contains { $0.path == "story.txt" })
        XCTAssertFalse(model.worktreeFiles.contains { $0.path == "scratch.txt" })
    }

    func testAppModelRestoresSelectedFileFromSelectedCommitToWorktree() async throws {
        let repo = try makeRepo()
        try write("old\n", to: repo, "story.txt")
        try commit("seed", repo: repo)
        try write("new\n", to: repo, "story.txt")
        try commit("update", repo: repo)
        let oldCommit = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try write("newer\n", to: repo, "story.txt")
        try commit("latest", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        let oldNode = try XCTUnwrap(model.commits.first { $0.id == oldCommit })
        model.selectCommit(oldNode)
        await waitForSelectedDiff(model, path: "story.txt")
        model.restoreSelectedFileFromSelectedCommit()
        await waitForWorktreeUpdate(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try read(repo, "story.txt"), "new\n")
        XCTAssertEqual(try require(["show", "HEAD:story.txt"], in: repo).standardOutput, "newer\n")
        XCTAssertTrue(model.worktreeFiles.contains { $0.path == "story.txt" && $0.workingTreeStatus == "M" })
        XCTAssertTrue(model.selectedWorktreePaths.contains("story.txt"))
        XCTAssertEqual(model.statusMessage, "Restored story.txt from selected commit.")
    }

    func testAppModelRestoreSelectedFileFromSelectedCommitPreservesGitFailure() async throws {
        let repo = try makeRepo()
        try write("story\n", to: repo, "story.txt")
        try commit("story", repo: repo)
        try write("story\nnext\n", to: repo, "story.txt")
        try commit("story next", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        let commit = try XCTUnwrap(model.commits.first)
        model.selectCommit(commit)
        await waitForSelectedDiff(model, path: "story.txt")
        model.selectedFilePath = "missing.txt"
        model.restoreSelectedFileFromSelectedCommit()
        await waitForWorktreeUpdate(model)

        XCTAssertEqual(model.statusMessage, "Restore needs attention.")
        XCTAssertTrue(model.errorMessage?.contains("git restore paths from commit failed") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("missing.txt").path))
        XCTAssertEqual(try logSubjects(repo).first, "story next")
    }

    func testAppModelSavesAppliesAndDropsStashOnGit() async throws {
        let repo = try makeRepo()
        try write("one\n", to: repo, "story.txt")
        try commit("seed", repo: repo)
        try write("two\n", to: repo, "story.txt")
        try write("scratch\n", to: repo, "scratch.txt")

        let model = AppModel()
        await model.openRepository(repo)
        model.stashMessage = "WIP story"
        model.saveStash()
        await waitForStashOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.worktreeFiles.isEmpty)
        XCTAssertEqual(model.stashes.first?.message, "WIP story")
        XCTAssertEqual(try read(repo, "story.txt"), "one\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("scratch.txt").path))

        model.applySelectedStash()
        await waitForStashOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.worktreeFiles.contains { $0.path == "story.txt" && $0.workingTreeStatus == "M" })
        XCTAssertTrue(model.worktreeFiles.contains { $0.path == "scratch.txt" && $0.displayStatus == "?" })
        XCTAssertEqual(try read(repo, "story.txt"), "two\n")

        model.dropSelectedStash()
        await waitForStashOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.stashes.isEmpty)
    }

    func testAppModelApplySelectedStashRequiresCleanWorkingTree() async throws {
        let repo = try makeRepo()
        try write("one\n", to: repo, "story.txt")
        try commit("seed", repo: repo)
        try write("stashed\n", to: repo, "story.txt")
        try await ShellGitHistoryService().saveStash(at: repo, message: "apply me")
        try write("dirty\n", to: repo, "dirty.txt")

        let model = AppModel()
        await model.openRepository(repo)
        XCTAssertEqual(model.stashes.first?.message, "apply me")
        model.applySelectedStash()
        await waitForStashOperation(model)

        XCTAssertEqual(model.errorMessage, "The working tree must be clean before rewriting history.")
        XCTAssertEqual(model.statusMessage, "Stash action needs attention.")
        XCTAssertEqual(model.stashes.first?.message, "apply me")
        XCTAssertEqual(try read(repo, "story.txt"), "one\n")
        XCTAssertEqual(try read(repo, "dirty.txt"), "dirty\n")
        XCTAssertTrue(model.worktreeFiles.contains { $0.path == "dirty.txt" && $0.displayStatus == "?" })
    }

    func testAppModelSavesSelectedWorktreePathsToStashOnGit() async throws {
        let repo = try makeRepo()
        try write("one\n", to: repo, "selected.txt")
        try write("keep\n", to: repo, "left-alone.txt")
        try commit("seed", repo: repo)
        try write("two\n", to: repo, "selected.txt")
        try write("changed\n", to: repo, "left-alone.txt")
        try write("scratch\n", to: repo, "scratch.txt")
        try write("unselected\n", to: repo, "unselected.txt")

        let model = AppModel()
        await model.openRepository(repo)
        model.selectedWorktreePaths = ["selected.txt", "scratch.txt"]
        model.stashMessage = "selected WIP"
        model.saveSelectedWorktreePathsToStash()
        await waitForStashOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.stashes.first?.message, "selected WIP")
        XCTAssertEqual(try read(repo, "selected.txt"), "one\n")
        XCTAssertEqual(try read(repo, "left-alone.txt"), "changed\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("scratch.txt").path))
        XCTAssertEqual(try read(repo, "unselected.txt"), "unselected\n")
        XCTAssertTrue(model.selectedWorktreePaths.isEmpty)
        XCTAssertTrue(model.worktreeFiles.contains { $0.path == "left-alone.txt" && $0.workingTreeStatus == "M" })
        XCTAssertTrue(model.worktreeFiles.contains { $0.path == "unselected.txt" && $0.displayStatus == "?" })
        XCTAssertFalse(model.worktreeFiles.contains { $0.path == "selected.txt" })
        XCTAssertFalse(model.worktreeFiles.contains { $0.path == "scratch.txt" })
        XCTAssertEqual(model.statusMessage, "Saved selected paths to stash.")
    }

    func testAppModelPopsSelectedStashOnGit() async throws {
        let repo = try makeRepo()
        try write("one\n", to: repo, "story.txt")
        try commit("seed", repo: repo)
        try write("two\n", to: repo, "story.txt")

        let model = AppModel()
        await model.openRepository(repo)
        model.stashMessage = "pop me"
        model.saveStash()
        await waitForStashOperation(model)
        model.popSelectedStash()
        await waitForStashOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try read(repo, "story.txt"), "two\n")
        XCTAssertTrue(model.stashes.isEmpty)
        XCTAssertTrue(model.worktreeFiles.contains { $0.path == "story.txt" && $0.workingTreeStatus == "M" })
        XCTAssertEqual(model.statusMessage, "Popped stash stash@{0}.")
    }

    func testAppModelPopSelectedStashRequiresCleanWorkingTree() async throws {
        let repo = try makeRepo()
        try write("one\n", to: repo, "story.txt")
        try commit("seed", repo: repo)
        try write("stashed\n", to: repo, "story.txt")
        try await ShellGitHistoryService().saveStash(at: repo, message: "pop me")
        try write("dirty\n", to: repo, "dirty.txt")

        let model = AppModel()
        await model.openRepository(repo)
        XCTAssertEqual(model.stashes.first?.message, "pop me")
        model.popSelectedStash()
        await waitForStashOperation(model)

        XCTAssertEqual(model.errorMessage, "The working tree must be clean before rewriting history.")
        XCTAssertEqual(model.statusMessage, "Stash pop needs attention.")
        XCTAssertEqual(model.stashes.first?.message, "pop me")
        XCTAssertEqual(try read(repo, "story.txt"), "one\n")
        XCTAssertEqual(try read(repo, "dirty.txt"), "dirty\n")
        XCTAssertTrue(model.conflicts.isEmpty)
        XCTAssertTrue(model.worktreeFiles.contains { $0.path == "dirty.txt" && $0.displayStatus == "?" })
    }

    func testAppModelPopSelectedStashSurfacesConflictAndFinishesAfterResolution() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "story.txt")
        try commit("seed", repo: repo)
        try write("stashed\n", to: repo, "story.txt")
        try await ShellGitHistoryService().saveStash(at: repo, message: "conflicting stash")
        try write("current\n", to: repo, "story.txt")
        try commit("current", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        XCTAssertEqual(model.stashes.first?.id, "stash@{0}")
        model.popSelectedStash()
        await waitForStashOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Stash pop has conflicts.")
        let conflict = try XCTUnwrap(model.conflicts.first)
        XCTAssertEqual(conflict.path, "story.txt")
        XCTAssertEqual(conflict.sections.map(\.side.rawValue), ["Your change", "REmote change"])
        XCTAssertEqual(model.activeConflictMode, .stashPop)
        XCTAssertEqual(model.stashes.first?.id, "stash@{0}")

        model.resolveConflict(conflict, taking: .remoteChange)
        await waitForRewrite(model)
        model.continueRebase()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.conflicts.isEmpty)
        XCTAssertTrue(model.stashes.isEmpty)
        XCTAssertEqual(try read(repo, "story.txt"), "stashed\n")
        XCTAssertEqual(model.statusMessage, "Finished stash pop.")
    }

    func testAppModelAbortSelectedStashPopRestoresCurrentTreeAndKeepsStash() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "story.txt")
        try commit("seed", repo: repo)
        try write("stashed\n", to: repo, "story.txt")
        try await ShellGitHistoryService().saveStash(at: repo, message: "conflicting stash")
        try write("current\n", to: repo, "story.txt")
        try commit("current", repo: repo)
        let prePopHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let model = AppModel()
        await model.openRepository(repo)
        XCTAssertEqual(model.stashes.first?.id, "stash@{0}")
        model.popSelectedStash()
        await waitForStashOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Stash pop has conflicts.")
        let conflict = try XCTUnwrap(model.conflicts.first)
        XCTAssertEqual(conflict.path, "story.txt")
        XCTAssertEqual(conflict.sections.map(\.side.rawValue), ["Your change", "REmote change"])
        XCTAssertEqual(model.activeConflictMode, .stashPop)

        model.abortRebase()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Aborted stash pop.")
        XCTAssertTrue(model.conflicts.isEmpty)
        XCTAssertEqual(model.stashes.first?.id, "stash@{0}")
        XCTAssertEqual(model.stashes.first?.message, "conflicting stash")
        XCTAssertEqual(try require(["rev-parse", "HEAD"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), prePopHead)
        XCTAssertEqual(try read(repo, "story.txt"), "current\n")
        XCTAssertTrue(model.worktreeFiles.isEmpty)
    }

    func testAppModelCreatesBranchFromSelectedStashOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "story.txt")
        try commit("seed", repo: repo)
        try write("stashed\n", to: repo, "story.txt")

        let model = AppModel()
        await model.openRepository(repo)
        model.stashMessage = "branch me"
        model.saveStash()
        await waitForStashOperation(model)
        model.newBranchName = "feature/stash-work"
        model.createBranchFromSelectedStash()
        await waitForStashOperation(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try require(["branch", "--show-current"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "feature/stash-work")
        XCTAssertEqual(try read(repo, "story.txt"), "stashed\n")
        XCTAssertTrue(model.stashes.isEmpty)
        XCTAssertEqual(model.newBranchName, "")
        XCTAssertTrue(model.worktreeFiles.contains { $0.path == "story.txt" && $0.workingTreeStatus == "M" })
        XCTAssertEqual(model.statusMessage, "Created branch feature/stash-work from stash.")
    }

    func testAppModelReverseSelectedCommitOrderLandsOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try write("a\n", to: repo, "a.txt")
        try commit("A", repo: repo)
        try write("b\n", to: repo, "b.txt")
        try commit("B", repo: repo)
        try write("c\n", to: repo, "c.txt")
        try commit("C", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        model.selectedCommitIDs = model.commits.prefix(3).map(\.id)
        model.reverseSelectedCommitOrder()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try logSubjects(repo), ["A", "B", "C", "base"])
        XCTAssertEqual(try read(repo, "a.txt"), "a\n")
        XCTAssertEqual(try read(repo, "b.txt"), "b\n")
        XCTAssertEqual(try read(repo, "c.txt"), "c\n")
    }

    func testAppModelPrepareSafetyBranchCreatesBranchAtCurrentHead() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try write("work\n", to: repo, "work.txt")
        try commit("work", repo: repo)
        let originalHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let model = AppModel()
        await model.openRepository(repo)
        model.prepareSafetyBranch()
        await waitForSafetyBranch(model)

        let safety = try XCTUnwrap(model.safetyBranchName)
        XCTAssertTrue(safety.hasPrefix("gitbud/safety-"))
        XCTAssertEqual(model.statusMessage, "Safety branch created: \(safety)")
        XCTAssertEqual(try require(["rev-parse", safety], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), originalHead)
        XCTAssertEqual(try require(["rev-parse", "HEAD"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), originalHead)
    }

    func testAppModelResetCurrentBranchToSelectedCommitKeepsChangesAndSafetyBranch() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let baseID = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try write("one\n", to: repo, "one.txt")
        try commit("one", repo: repo)
        try write("two\n", to: repo, "two.txt")
        try commit("two", repo: repo)
        let originalHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let model = AppModel()
        await model.openRepository(repo)
        let baseNode = try XCTUnwrap(model.commits.first { $0.id == baseID })
        model.selectCommit(baseNode)
        model.resetCurrentBranchToSelectedCommit()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Reset current branch to selected commit.")
        XCTAssertEqual(try require(["rev-parse", "HEAD"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), baseID)
        let safety = try XCTUnwrap(model.safetyBranchName)
        XCTAssertEqual(try require(["rev-parse", safety], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), originalHead)
        XCTAssertTrue(model.worktreeFiles.contains { $0.path == "one.txt" && $0.displayStatus == "?" })
        XCTAssertTrue(model.worktreeFiles.contains { $0.path == "two.txt" && $0.displayStatus == "?" })
        XCTAssertEqual(try read(repo, "one.txt"), "one\n")
        XCTAssertEqual(try read(repo, "two.txt"), "two\n")
    }

    func testAppModelResetCurrentBranchToSelectedCommitRequiresCleanWorkingTree() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let baseID = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try write("one\n", to: repo, "one.txt")
        try commit("one", repo: repo)
        let originalHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try write("dirty\n", to: repo, "dirty.txt")

        let model = AppModel()
        await model.openRepository(repo)
        let baseNode = try XCTUnwrap(model.commits.first { $0.id == baseID })
        model.selectCommit(baseNode)
        model.resetCurrentBranchToSelectedCommit()
        await waitForRewrite(model)

        XCTAssertEqual(model.errorMessage, "The working tree must be clean before rewriting history.")
        XCTAssertEqual(model.statusMessage, "Reset needs attention.")
        XCTAssertEqual(try require(["rev-parse", "HEAD"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), originalHead)
        XCTAssertEqual(try logSubjects(repo), ["one", "base"])
        XCTAssertEqual(try read(repo, "dirty.txt"), "dirty\n")
    }

    func testAppModelRecoverCurrentBranchToSelectedReflogEntryLandsOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let baseID = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try write("one\n", to: repo, "one.txt")
        try commit("one", repo: repo)
        try write("two\n", to: repo, "two.txt")
        try commit("two", repo: repo)
        let originalHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(["reset", "--hard", baseID], in: repo)

        let model = AppModel()
        await model.openRepository(repo)
        let recoveryEntry = try XCTUnwrap(model.reflogEntries.first { $0.commitID == originalHead })
        model.selectedReflogEntryID = recoveryEntry.id
        model.recoverCurrentBranchToSelectedReflogEntry()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Recovered current branch to \(recoveryEntry.selector).")
        XCTAssertEqual(try require(["rev-parse", "HEAD"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), originalHead)
        let safety = try XCTUnwrap(model.safetyBranchName)
        XCTAssertEqual(try require(["rev-parse", safety], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), baseID)
        XCTAssertEqual(try logSubjects(repo), ["two", "one", "base"])
        XCTAssertEqual(try read(repo, "one.txt"), "one\n")
        XCTAssertEqual(try read(repo, "two.txt"), "two\n")
        XCTAssertTrue(model.worktreeFiles.isEmpty)
    }

    func testAppModelRecoverCurrentBranchToSelectedReflogEntryRequiresCleanWorkingTree() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let baseID = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try write("one\n", to: repo, "one.txt")
        try commit("one", repo: repo)
        let originalHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(["reset", "--hard", baseID], in: repo)
        try write("dirty\n", to: repo, "dirty.txt")

        let model = AppModel()
        await model.openRepository(repo)
        let recoveryEntry = try XCTUnwrap(model.reflogEntries.first { $0.commitID == originalHead })
        model.selectedReflogEntryID = recoveryEntry.id
        model.recoverCurrentBranchToSelectedReflogEntry()
        await waitForRewrite(model)

        XCTAssertEqual(model.errorMessage, "The working tree must be clean before rewriting history.")
        XCTAssertEqual(model.statusMessage, "Recovery needs attention.")
        XCTAssertEqual(try require(["rev-parse", "HEAD"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), baseID)
        XCTAssertEqual(try logSubjects(repo), ["base"])
        XCTAssertEqual(try read(repo, "dirty.txt"), "dirty\n")
    }

    func testAppModelRevertSelectedCommitLandsOnGit() async throws {
        let repo = try makeRepo()
        try write("one\n", to: repo, "story.txt")
        try commit("base", repo: repo)
        try write("two\n", to: repo, "story.txt")
        try commit("change story", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        model.revertSelectedCommit()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Reverted selected commit.")
        XCTAssertEqual(try read(repo, "story.txt"), "one\n")
        XCTAssertEqual(try logSubjects(repo).first, "Revert \"change story\"")
        XCTAssertTrue(model.conflicts.isEmpty)
    }

    func testAppModelRevertSelectedCommitRequiresCleanWorkingTree() async throws {
        let repo = try makeRepo()
        try write("one\n", to: repo, "story.txt")
        try commit("base", repo: repo)
        try write("two\n", to: repo, "story.txt")
        try commit("change story", repo: repo)
        let originalHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try write("dirty\n", to: repo, "dirty.txt")

        let model = AppModel()
        await model.openRepository(repo)
        model.revertSelectedCommit()
        await waitForRewrite(model)

        XCTAssertEqual(model.errorMessage, "The working tree must be clean before rewriting history.")
        XCTAssertEqual(model.statusMessage, "Rewrite needs attention.")
        XCTAssertEqual(try require(["rev-parse", "HEAD"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), originalHead)
        XCTAssertEqual(try logSubjects(repo), ["change story", "base"])
        XCTAssertEqual(try read(repo, "story.txt"), "two\n")
        XCTAssertEqual(try read(repo, "dirty.txt"), "dirty\n")
        XCTAssertTrue(model.conflicts.isEmpty)
    }

    func testAppModelRevertSelectedCommitSurfacesConflictAndContinues() async throws {
        let repo = try makeRepo()
        try write("one\n", to: repo, "story.txt")
        try commit("base", repo: repo)
        try write("two\n", to: repo, "story.txt")
        try commit("target change", repo: repo)
        let target = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try write("three\n", to: repo, "story.txt")
        try commit("later change", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        model.focusedCommitID = target
        model.revertSelectedCommit()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Revert has conflicts.")
        let conflict = try XCTUnwrap(model.conflicts.first)
        XCTAssertEqual(conflict.path, "story.txt")
        XCTAssertEqual(conflict.sections.map(\.side.rawValue), ["Your change", "REmote change"])
        model.conflictDrafts[conflict.path] = "manual revert\n"
        model.resolveConflictWithDraft(conflict)
        await waitForRewrite(model)
        model.continueRebase()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Continued revert.")
        XCTAssertEqual(try read(repo, "story.txt"), "manual revert\n")
        XCTAssertEqual(try logSubjects(repo).first, "Revert \"target change\"")
        XCTAssertTrue(model.conflicts.isEmpty)
    }

    func testAppModelRevertConflictTakingYourChangeSkipsEmptyRevertOnGit() async throws {
        let repo = try makeRepo()
        try write("one\n", to: repo, "story.txt")
        try commit("base", repo: repo)
        try write("two\n", to: repo, "story.txt")
        try commit("target change", repo: repo)
        let target = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try write("three\n", to: repo, "story.txt")
        try commit("later change", repo: repo)
        let preRevertHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let model = AppModel()
        await model.openRepository(repo)
        model.focusedCommitID = target
        model.revertSelectedCommit()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        let conflict = try XCTUnwrap(model.conflicts.first)
        XCTAssertEqual(conflict.sections.map(\.side.rawValue), ["Your change", "REmote change"])
        model.resolveConflict(conflict, taking: .yourChange)
        await waitForRewrite(model)
        model.continueRebase()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Continued revert.")
        XCTAssertTrue(model.conflicts.isEmpty)
        XCTAssertEqual(try read(repo, "story.txt"), "three\n")
        XCTAssertEqual(try require(["rev-parse", "HEAD"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), preRevertHead)
        XCTAssertFalse(try runner.run(["rev-parse", "-q", "--verify", "REVERT_HEAD"], in: repo).succeeded)
    }

    func testAppModelAbortRevertSelectedCommitRestoresPreRevertStateOnGit() async throws {
        let repo = try makeRepo()
        try write("one\n", to: repo, "story.txt")
        try commit("base", repo: repo)
        try write("two\n", to: repo, "story.txt")
        try commit("target change", repo: repo)
        let target = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try write("three\n", to: repo, "story.txt")
        try commit("later change", repo: repo)
        let preRevertHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let model = AppModel()
        await model.openRepository(repo)
        model.focusedCommitID = target
        model.revertSelectedCommit()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Revert has conflicts.")
        let conflict = try XCTUnwrap(model.conflicts.first)
        XCTAssertEqual(conflict.path, "story.txt")
        XCTAssertEqual(conflict.sections.map(\.side.rawValue), ["Your change", "REmote change"])
        XCTAssertEqual(model.activeConflictMode, .revert)

        model.abortRebase()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Aborted revert.")
        XCTAssertTrue(model.conflicts.isEmpty)
        XCTAssertEqual(try require(["rev-parse", "HEAD"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), preRevertHead)
        XCTAssertEqual(try read(repo, "story.txt"), "three\n")
        XCTAssertFalse(try runner.run(["rev-parse", "-q", "--verify", "REVERT_HEAD"], in: repo).succeeded)
    }

    func testAppModelCherryPickSelectedCommitLandsOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        let initialBranch = try require(["branch", "--show-current"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(["switch", "-c", "feature/cherry"], in: repo)
        try write("feature\n", to: repo, "feature.txt")
        try commit("feature change", repo: repo)
        let featureCommit = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(["switch", initialBranch], in: repo)

        let model = AppModel()
        await model.openRepository(repo)
        model.focusedCommitID = featureCommit
        model.cherryPickSelectedCommit()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Cherry-picked selected commit.")
        XCTAssertEqual(try read(repo, "feature.txt"), "feature\n")
        XCTAssertEqual(try logSubjects(repo).first, "feature change")
        XCTAssertTrue(model.conflicts.isEmpty)
    }

    func testAppModelCherryPickSelectedCommitSurfacesConflictAndContinues() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "story.txt")
        try commit("base", repo: repo)
        let initialBranch = try require(["branch", "--show-current"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(["switch", "-c", "feature/cherry-conflict"], in: repo)
        try write("picked\n", to: repo, "story.txt")
        try commit("picked change", repo: repo)
        let picked = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(["switch", initialBranch], in: repo)
        try write("current\n", to: repo, "story.txt")
        try commit("current change", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        model.focusedCommitID = picked
        model.cherryPickSelectedCommit()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Cherry-pick has conflicts.")
        let conflict = try XCTUnwrap(model.conflicts.first)
        XCTAssertEqual(conflict.path, "story.txt")
        XCTAssertEqual(conflict.sections.map(\.side.rawValue), ["Your change", "REmote change"])
        model.conflictDrafts[conflict.path] = "manual cherry\n"
        model.resolveConflictWithDraft(conflict)
        await waitForRewrite(model)
        model.continueRebase()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Continued cherry-pick.")
        XCTAssertEqual(try read(repo, "story.txt"), "manual cherry\n")
        XCTAssertEqual(try logSubjects(repo).first, "picked change")
        XCTAssertTrue(model.conflicts.isEmpty)
    }

    func testAppModelCherryPickConflictTakingYourChangeSkipsEmptyPickOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "story.txt")
        try commit("base", repo: repo)
        let initialBranch = try require(["branch", "--show-current"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(["switch", "-c", "feature/cherry-empty"], in: repo)
        try write("picked\n", to: repo, "story.txt")
        try commit("picked change", repo: repo)
        let picked = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(["switch", initialBranch], in: repo)
        try write("current\n", to: repo, "story.txt")
        try commit("current change", repo: repo)
        let prePickHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let model = AppModel()
        await model.openRepository(repo)
        model.focusedCommitID = picked
        model.cherryPickSelectedCommit()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        let conflict = try XCTUnwrap(model.conflicts.first)
        XCTAssertEqual(conflict.sections.map(\.side.rawValue), ["Your change", "REmote change"])
        model.resolveConflict(conflict, taking: .yourChange)
        await waitForRewrite(model)
        model.continueRebase()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Continued cherry-pick.")
        XCTAssertTrue(model.conflicts.isEmpty)
        XCTAssertEqual(try read(repo, "story.txt"), "current\n")
        XCTAssertEqual(try require(["rev-parse", "HEAD"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), prePickHead)
        XCTAssertFalse(try runner.run(["rev-parse", "-q", "--verify", "CHERRY_PICK_HEAD"], in: repo).succeeded)
    }

    func testAppModelAbortCherryPickSelectedCommitRestoresPrePickStateOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "story.txt")
        try commit("base", repo: repo)
        let initialBranch = try require(["branch", "--show-current"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(["switch", "-c", "feature/cherry-abort"], in: repo)
        try write("picked\n", to: repo, "story.txt")
        try commit("picked change", repo: repo)
        let picked = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(["switch", initialBranch], in: repo)
        try write("current\n", to: repo, "story.txt")
        try commit("current change", repo: repo)
        let prePickHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let model = AppModel()
        await model.openRepository(repo)
        model.focusedCommitID = picked
        model.cherryPickSelectedCommit()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Cherry-pick has conflicts.")
        let conflict = try XCTUnwrap(model.conflicts.first)
        XCTAssertEqual(conflict.path, "story.txt")
        XCTAssertEqual(conflict.sections.map(\.side.rawValue), ["Your change", "REmote change"])
        XCTAssertEqual(model.activeConflictMode, .cherryPick)

        model.abortRebase()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Aborted cherry-pick.")
        XCTAssertTrue(model.conflicts.isEmpty)
        XCTAssertEqual(try require(["branch", "--show-current"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), initialBranch)
        XCTAssertEqual(try require(["rev-parse", "HEAD"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), prePickHead)
        XCTAssertEqual(try read(repo, "story.txt"), "current\n")
        XCTAssertFalse(try runner.run(["rev-parse", "-q", "--verify", "CHERRY_PICK_HEAD"], in: repo).succeeded)
    }

    func testAppModelMoveSelectedCommitInRewritePlanLandsOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try write("a\n", to: repo, "a.txt")
        try commit("A", repo: repo)
        try write("b\n", to: repo, "b.txt")
        try commit("B", repo: repo)
        try write("c\n", to: repo, "c.txt")
        try commit("C", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        model.selectedCommitIDs = model.commits.prefix(3).map(\.id)
        model.focusedCommitID = model.commits[0].id
        model.moveFocusedCommitLater()
        await waitForRewritePreview(model)

        XCTAssertEqual(model.selectedCommitIDs.compactMap { id in model.commits.first { $0.id == id }?.subject }, ["B", "C", "A"])
        XCTAssertEqual(model.rewritePreview?.plannedOldestToNewest.map(\.subject), ["A", "C", "B"])
        model.applyPlannedCommitOrder()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try logSubjects(repo), ["B", "C", "A", "base"])
        XCTAssertEqual(try read(repo, "a.txt"), "a\n")
        XCTAssertEqual(try read(repo, "b.txt"), "b\n")
        XCTAssertEqual(try read(repo, "c.txt"), "c\n")
    }

    func testAppModelMoveSelectedCommitEarlierInRewritePlanLandsOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try write("a\n", to: repo, "a.txt")
        try commit("A", repo: repo)
        try write("b\n", to: repo, "b.txt")
        try commit("B", repo: repo)
        try write("c\n", to: repo, "c.txt")
        try commit("C", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        model.selectedCommitIDs = model.commits.prefix(3).map(\.id)
        model.focusedCommitID = model.commits[1].id
        model.moveFocusedCommitEarlier()
        await waitForRewritePreview(model)

        XCTAssertEqual(model.selectedCommitIDs.compactMap { id in model.commits.first { $0.id == id }?.subject }, ["B", "C", "A"])
        XCTAssertEqual(model.rewritePreview?.plannedOldestToNewest.map(\.subject), ["A", "C", "B"])
        model.applyPlannedCommitOrder()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try logSubjects(repo), ["B", "C", "A", "base"])
        XCTAssertEqual(try read(repo, "a.txt"), "a\n")
        XCTAssertEqual(try read(repo, "b.txt"), "b\n")
        XCTAssertEqual(try read(repo, "c.txt"), "c\n")
    }

    func testAppModelDropSelectedCommitLandsOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try write("drop\n", to: repo, "drop.txt")
        try commit("drop me", repo: repo)
        let dropID = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try write("keep\n", to: repo, "keep.txt")
        try commit("keep me", repo: repo)
        let originalHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let model = AppModel()
        await model.openRepository(repo)
        let dropNode = try XCTUnwrap(model.commits.first { $0.id == dropID })
        model.selectCommit(dropNode)
        model.dropSelectedCommit()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Dropped selected commit.")
        let safety = try XCTUnwrap(model.safetyBranchName)
        XCTAssertEqual(try require(["rev-parse", safety], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), originalHead)
        XCTAssertEqual(try logSubjects(repo), ["keep me", "base"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("drop.txt").path))
        XCTAssertEqual(try read(repo, "keep.txt"), "keep\n")
    }

    func testAppModelDeleteSelectedFileLandsOnGit() async throws {
        let repo = try makeRepo()
        try write("keep\n", to: repo, "keep.txt")
        try write("delete\n", to: repo, "delete.txt")
        try commit("seed", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        model.selectedFilePath = "delete.txt"
        model.deleteSelectedFile()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try logSubjects(repo), ["Delete delete.txt", "seed"])
        XCTAssertEqual(try read(repo, "keep.txt"), "keep\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("delete.txt").path))
    }

    func testAppModelPurgeSelectedFileFromHistoryLandsOnGit() async throws {
        let repo = try makeRepo()
        try write("public 1\n", to: repo, "public.txt")
        try write("secret 1\n", to: repo, "secret.txt")
        try commit("seed with secret", repo: repo)
        try write("public 2\n", to: repo, "public.txt")
        try write("secret 2\n", to: repo, "secret.txt")
        try commit("update secret", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        let secretFile = try XCTUnwrap(model.changedFiles.first { $0.path == "secret.txt" })
        model.selectFile(secretFile)
        await waitForPurgePreview(model, path: "secret.txt")
        XCTAssertEqual(model.purgePreview?.paths, ["secret.txt"])
        XCTAssertEqual(model.purgePreview?.affectedCommits.map(\.subject), ["update secret", "seed with secret"])

        model.purgeSelectedFileFromHistory()
        XCTAssertEqual(model.statusMessage, "Type PURGE secret.txt before purging history.")
        XCTAssertNil(model.safetyBranchName)
        XCTAssertEqual(try logSubjects(repo), ["update secret", "seed with secret"])
        XCTAssertEqual(try read(repo, "secret.txt"), "secret 2\n")

        model.purgeConfirmationText = "PURGE secret.txt"
        model.purgeSelectedFileFromHistory()
        await waitForRewrite(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.safetyBranchName)
        XCTAssertEqual(model.purgeConfirmationText, "")
        XCTAssertEqual(try read(repo, "public.txt"), "public 2\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("secret.txt").path))
        let commits = try require(["rev-list", "HEAD"], in: repo).standardOutput.split(separator: "\n").map(String.init)
        for commit in commits {
            let tree = try require(["ls-tree", "-r", "--name-only", commit], in: repo).standardOutput
            XCTAssertFalse(tree.split(separator: "\n").contains("secret.txt"))
        }
    }

    func testAppModelPurgeSelectedFileFromHistoryRequiresCleanWorkingTree() async throws {
        let repo = try makeRepo()
        try write("public 1\n", to: repo, "public.txt")
        try write("secret 1\n", to: repo, "secret.txt")
        try commit("seed with secret", repo: repo)
        try write("public 2\n", to: repo, "public.txt")
        try write("secret 2\n", to: repo, "secret.txt")
        try commit("update secret", repo: repo)
        let originalHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let model = AppModel()
        await model.openRepository(repo)
        let secretFile = try XCTUnwrap(model.changedFiles.first { $0.path == "secret.txt" })
        model.selectFile(secretFile)
        await waitForPurgePreview(model, path: "secret.txt")
        try write("dirty\n", to: repo, "dirty.txt")
        model.purgeConfirmationText = "PURGE secret.txt"
        model.purgeSelectedFileFromHistory()
        await waitForRewrite(model)

        XCTAssertEqual(model.errorMessage, "The working tree must be clean before rewriting history.")
        XCTAssertEqual(model.statusMessage, "Purge needs attention.")
        XCTAssertEqual(try require(["rev-parse", "HEAD"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), originalHead)
        XCTAssertEqual(try logSubjects(repo), ["update secret", "seed with secret"])
        XCTAssertEqual(try read(repo, "secret.txt"), "secret 2\n")
        XCTAssertEqual(try read(repo, "dirty.txt"), "dirty\n")
    }

    func testAppModelPurgeSelectedFileFromHistoryRequiresLoadedPreview() async throws {
        let repo = try makeRepo()
        try write("public 1\n", to: repo, "public.txt")
        try write("secret 1\n", to: repo, "secret.txt")
        try commit("seed with secret", repo: repo)
        try write("public 2\n", to: repo, "public.txt")
        try write("secret 2\n", to: repo, "secret.txt")
        try commit("update secret", repo: repo)
        let originalHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let model = AppModel()
        await model.openRepository(repo)
        model.selectedFilePath = "secret.txt"
        model.purgeConfirmationText = "PURGE secret.txt"
        model.purgeSelectedFileFromHistory()

        XCTAssertEqual(model.statusMessage, "Load the purge preview before rewriting history.")
        XCTAssertFalse(model.isPurgeConfirmed)
        XCTAssertNil(model.safetyBranchName)
        XCTAssertEqual(try require(["rev-parse", "HEAD"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), originalHead)
        XCTAssertEqual(try logSubjects(repo), ["update secret", "seed with secret"])
        XCTAssertEqual(try read(repo, "secret.txt"), "secret 2\n")
    }

    func testAppModelPushRewrittenBranchWithLeaseLandsOnRemote() async throws {
        let remote = tmp.appendingPathComponent("remote.git")
        try require(["init", "--bare", remote.path], in: tmp)
        let repo = tmp.appendingPathComponent("repo")
        try require(["clone", remote.path, repo.path], in: tmp)
        try configureIdentity(repo, name: "GitBud Test")
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try require(["push", "-u", "origin", "HEAD"], in: repo)
        try require(["switch", "-c", "feature/rewrite"], in: repo)
        try write("one\n", to: repo, "one.txt")
        try commit("one", repo: repo)
        try require(["push", "-u", "origin", "HEAD"], in: repo)
        let branch = try require(["branch", "--show-current"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let suiteName = "app.hakobs.gitbud.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GitBudSettingsStore(defaults: defaults)
        let model = AppModel(settingsStore: store)
        await model.openRepository(repo)
        model.editHeadCommitMessage()
        await waitForRewrite(model)
        XCTAssertTrue(model.canForcePush)
        model.pushRewrittenBranchWithLease()
        XCTAssertEqual(model.statusMessage, "Type FORCE PUSH \(branch) before pushing rewritten history.")
        let unchangedRemoteSubject = try require(["--git-dir", remote.path, "log", "--format=%s", "-1", "refs/heads/\(branch)"], in: tmp).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(unchangedRemoteSubject, "one")

        model.forcePushConfirmationText = "FORCE PUSH \(branch)"
        model.pushRewrittenBranchWithLease()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.forcePushConfirmationText, "")
        let remoteSubject = try require(["--git-dir", remote.path, "log", "--format=%s", "-1", "refs/heads/\(branch)"], in: tmp).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(remoteSubject, "Refine: one")
    }

    func testAppModelPushRewrittenBranchWithLeaseRejectsStaleRemote() async throws {
        let remote = tmp.appendingPathComponent("stale-lease-remote.git")
        try require(["init", "--bare", remote.path], in: tmp)
        let repo = tmp.appendingPathComponent("stale-lease-repo")
        let other = tmp.appendingPathComponent("stale-lease-other")
        try require(["clone", remote.path, repo.path], in: tmp)
        try configureIdentity(repo, name: "GitBud Lease")
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try require(["push", "-u", "origin", "HEAD"], in: repo)
        try require(["switch", "-c", "feature/rewrite"], in: repo)
        try write("one\n", to: repo, "one.txt")
        try commit("one", repo: repo)
        try require(["push", "-u", "origin", "HEAD"], in: repo)
        try require(["clone", remote.path, other.path], in: tmp)
        try configureIdentity(other, name: "Other Writer")
        try require(["switch", "feature/rewrite"], in: other)

        let suiteName = "app.hakobs.gitbud.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GitBudSettingsStore(defaults: defaults)
        let model = AppModel(settingsStore: store)
        await model.openRepository(repo)
        model.editHeadCommitMessage()
        await waitForRewrite(model)
        XCTAssertTrue(model.canForcePush)

        try write("remote two\n", to: other, "remote.txt")
        try commit("remote two", repo: other)
        try require(["push"], in: other)
        let otherHead = try require(["rev-parse", "HEAD"], in: other).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)

        model.forcePushConfirmationText = "FORCE PUSH feature/rewrite"
        model.pushRewrittenBranchWithLease()
        await waitForRewrite(model)

        XCTAssertEqual(model.statusMessage, "Push needs attention.")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.forcePushConfirmationText, "FORCE PUSH feature/rewrite")
        XCTAssertEqual(
            try require(["--git-dir", remote.path, "rev-parse", "refs/heads/feature/rewrite"], in: tmp).standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines),
            otherHead
        )
        XCTAssertEqual(
            try require(["--git-dir", remote.path, "log", "--format=%s", "-1", "refs/heads/feature/rewrite"], in: tmp).standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "remote two"
        )
    }

    func testAppModelPushRewrittenBranchWithLeaseRequiresReadyBranch() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try require(["switch", "-c", "feature/local-only"], in: repo)
        try write("one\n", to: repo, "one.txt")
        try commit("one", repo: repo)
        let originalHead = try require(["rev-parse", "HEAD"], in: repo).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let model = AppModel()
        await model.openRepository(repo)
        model.editHeadCommitMessage()
        await waitForRewrite(model)
        XCTAssertFalse(model.canForcePush)

        model.forcePushConfirmationText = "FORCE PUSH feature/local-only"
        model.pushRewrittenBranchWithLease()

        XCTAssertEqual(model.statusMessage, "Force-with-lease is not ready for this branch.")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isRewriting)
        XCTAssertEqual(model.forcePushConfirmationText, "FORCE PUSH feature/local-only")
        XCTAssertNotEqual(
            try require(["rev-parse", "HEAD"], in: repo).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            originalHead
        )
        XCTAssertFalse(try runner.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: repo).succeeded)
    }

    func testAppModelProtectedBranchBlocksDirectRewritePush() async throws {
        let remote = tmp.appendingPathComponent("protected-remote.git")
        try require(["init", "--bare", remote.path], in: tmp)
        let repo = tmp.appendingPathComponent("protected-repo")
        try require(["clone", remote.path, repo.path], in: tmp)
        try configureIdentity(repo, name: "GitBud Protected")
        try require(["switch", "-c", "main"], in: repo)
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try require(["push", "-u", "origin", "HEAD"], in: repo)
        try write("one\n", to: repo, "one.txt")
        try commit("one", repo: repo)
        try require(["push"], in: repo)

        let suiteName = "app.hakobs.gitbud.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GitBudSettingsStore(defaults: defaults)
        let model = AppModel(settingsStore: store)
        await model.openRepository(repo)
        model.editHeadCommitMessage()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isCurrentBranchProtected)
        XCTAssertFalse(model.canForcePush)
        model.pushRewrittenBranchWithLease()

        XCTAssertEqual(model.statusMessage, "Protected branches should use a new branch and draft PR.")
        let remoteSubject = try require(["--git-dir", remote.path, "log", "--format=%s", "-1", "refs/heads/main"], in: tmp).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(remoteSubject, "one")
    }

    func testAppModelCustomProtectedBranchPolicyBlocksMatchingRewritePush() async throws {
        let remote = tmp.appendingPathComponent("custom-protected-remote.git")
        try require(["init", "--bare", remote.path], in: tmp)
        let repo = tmp.appendingPathComponent("custom-protected-repo")
        try require(["clone", remote.path, repo.path], in: tmp)
        try configureIdentity(repo, name: "GitBud Custom Protected")
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try require(["push", "-u", "origin", "HEAD"], in: repo)
        try require(["switch", "-c", "feature/rewrite"], in: repo)
        try write("one\n", to: repo, "one.txt")
        try commit("one", repo: repo)
        try require(["push", "-u", "origin", "HEAD"], in: repo)

        let suiteName = "app.hakobs.gitbud.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GitBudSettingsStore(defaults: defaults)
        let model = AppModel(settingsStore: store)
        model.protectedBranchPatternsText = "feature/*"
        model.saveProtectedBranchPolicy()
        await model.openRepository(repo)
        model.editHeadCommitMessage()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isCurrentBranchProtected)
        XCTAssertFalse(model.canForcePush)
        model.pushRewrittenBranchWithLease()

        XCTAssertEqual(model.statusMessage, "Protected branches should use a new branch and draft PR.")
        let remoteSubject = try require(["--git-dir", remote.path, "log", "--format=%s", "-1", "refs/heads/feature/rewrite"], in: tmp).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(remoteSubject, "one")
    }

    func testAppModelResolveConflictTakingYourChangeLandsOnGit() async throws {
        let repo = try makeRebaseConflict()
        let model = AppModel()
        await model.openRepository(repo)
        let conflict = try XCTUnwrap(model.conflicts.first)

        model.resolveConflict(conflict, taking: .yourChange)
        await waitForRewrite(model)
        model.continueRebase()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try read(repo, "conflict.txt"), "local\n")
        XCTAssertTrue(model.conflicts.isEmpty)
    }

    func testAppModelResolveConflictWithEditedContentLandsOnGit() async throws {
        let repo = try makeRebaseConflict()
        let model = AppModel()
        await model.openRepository(repo)
        let conflict = try XCTUnwrap(model.conflicts.first)

        XCTAssertEqual(model.conflictDrafts[conflict.path], "remote\nlocal\n")
        model.conflictDrafts[conflict.path] = "manual resolution\n"
        model.resolveConflictWithDraft(conflict)
        await waitForRewrite(model)
        model.continueRebase()
        await waitForRewrite(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try read(repo, "conflict.txt"), "manual resolution\n")
        XCTAssertTrue(model.conflicts.isEmpty)
    }

    func testAppModelUndoLastRewriteRestoresThePreviousHeadOnGit() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try write("a\n", to: repo, "a.txt")
        try commit("A", repo: repo)
        try write("b\n", to: repo, "b.txt")
        try commit("B", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        let dropped = try XCTUnwrap(model.commits.first { $0.subject == "A" })
        model.selectCommit(dropped)
        model.dropSelectedCommit()
        await waitForRewrite(model)

        XCTAssertEqual(try logSubjects(repo), ["B", "base"])
        let undo = try XCTUnwrap(model.rewriteUndo, "a rewrite should offer a way back")

        model.undoLastRewrite()
        await waitForUndo(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try logSubjects(repo), ["B", "A", "base"])
        XCTAssertNil(model.rewriteUndo)
        XCTAssertTrue(undo.safetyBranch.hasPrefix("gitbud/safety"))
    }

    func testAppModelLoadMoreHistoryFetchesOlderCommits() async throws {
        let repo = try makeRepo()
        for index in 1...5 {
            try write("\(index)\n", to: repo, "file\(index).txt")
            try commit("commit \(index)", repo: repo)
        }

        let model = AppModel()
        model.historyLimit = 2
        await model.openRepository(repo)

        XCTAssertEqual(model.commits.count, 2)
        XCTAssertTrue(model.canLoadMoreHistory)

        model.loadMoreHistory()
        await waitForMoreHistory(model)

        XCTAssertEqual(model.commits.count, 5)
        XCTAssertFalse(model.canLoadMoreHistory, "the window is now larger than the history")
    }

    func testAppModelGraphRowsPlaceMergesInTheirOwnLane() async throws {
        let repo = try makeRepo()
        try write("base\n", to: repo, "base.txt")
        try commit("base", repo: repo)
        try require(["checkout", "-b", "feature"], in: repo)
        try write("feature\n", to: repo, "feature.txt")
        try commit("feature work", repo: repo)
        try require(["checkout", "-"], in: repo)
        try write("trunk\n", to: repo, "trunk.txt")
        try commit("trunk work", repo: repo)
        try require(["merge", "--no-ff", "feature", "-m", "merge feature"], in: repo)

        let model = AppModel()
        await model.openRepository(repo)

        let rows = model.graphRows
        let merge = try XCTUnwrap(rows.first { $0.commit.subject == "merge feature" })
        XCTAssertEqual(merge.commit.parentIDs.count, 2)
        XCTAssertTrue(merge.edges.contains { $0.kind == .diverge }, "a merge should fan out below its dot")
        XCTAssertGreaterThan(rows.map(\.laneCount).max() ?? 0, 1, "the branch should occupy a second lane")
    }

    func testAppModelSelectCommitReplacesTheMultiSelection() async throws {
        let repo = try makeRepo()
        try write("a\n", to: repo, "a.txt")
        try commit("A", repo: repo)
        try write("b\n", to: repo, "b.txt")
        try commit("B", repo: repo)

        let model = AppModel()
        await model.openRepository(repo)
        model.selectedCommitIDs = model.commits.map(\.id)
        XCTAssertEqual(model.selectedCommitIDs.count, 2)

        let single = try XCTUnwrap(model.commits.last)
        model.selectCommit(single)

        XCTAssertEqual(model.selectedCommitIDs, [single.id])
        XCTAssertEqual(model.focusedCommitID, single.id)
    }

    func testAppModelExtendCommitSelectionCoversTheRangeInGraphOrder() async throws {
        let repo = try makeRepo()
        for subject in ["A", "B", "C", "D"] {
            try write("\(subject)\n", to: repo, "\(subject).txt")
            try commit(subject, repo: repo)
        }

        let model = AppModel()
        await model.openRepository(repo)
        // Newest first: D, C, B, A
        model.selectCommit(try XCTUnwrap(model.commits.first))
        model.extendCommitSelection(to: try XCTUnwrap(model.commits[2]))

        XCTAssertEqual(
            model.selectedCommitIDs.compactMap { id in model.commits.first { $0.id == id }?.subject },
            ["D", "C", "B"]
        )
    }

    private func waitForUndo(_ model: AppModel) async {
        for _ in 0..<60 {
            if !model.isUndoingRewrite && !model.isLoading { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for undo")
    }

    private func waitForMoreHistory(_ model: AppModel) async {
        for _ in 0..<60 {
            if !model.isLoadingMoreHistory { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for more history")
    }

    private func makeRepo() throws -> URL {
        let repo = tmp.appendingPathComponent("repo")
        try require(["init", repo.path], in: tmp)
        try configureIdentity(repo, name: "GitBud Test")
        return repo
    }

    private func configureIdentity(_ repo: URL, name: String) throws {
        try require(["config", "user.email", "\(name.lowercased())@example.com"], in: repo)
        try require(["config", "user.name", name], in: repo)
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

    private func read(_ repo: URL, _ path: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    private func logSubjects(_ repo: URL) throws -> [String] {
        try require(["log", "--format=%s"], in: repo).standardOutput
            .split(separator: "\n")
            .map(String.init)
    }

    private func waitForRewrite(_ model: AppModel) async {
        for _ in 0..<60 {
            if !model.isRewriting && !model.isLoading { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for rewrite")
    }

    private func waitForSafetyBranch(_ model: AppModel) async {
        for _ in 0..<60 {
            if model.safetyBranchName != nil { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for safety branch")
    }

    private func waitForMagic(_ model: AppModel) async {
        for _ in 0..<60 {
            if !model.isDraftingMagic { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for Magic")
    }

    private func waitForClone(_ model: AppModel) async {
        for _ in 0..<80 {
            if !model.isCloningRemote && !model.isLoading { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for clone")
    }

    private func waitForProviderRepositories(_ model: AppModel) async {
        for _ in 0..<60 {
            if !model.isLoadingRemoteRepositories { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for provider repositories")
    }

    private func waitForProviderConnection(_ model: AppModel) async {
        for _ in 0..<60 {
            if !model.isConnectingProviderAccount { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for provider connection")
    }

    private func waitForPullRequest(_ model: AppModel) async {
        for _ in 0..<60 {
            if !model.isCreatingPullRequest { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for pull request")
    }

    private func waitForPullRequestList(_ model: AppModel) async {
        for _ in 0..<60 {
            if !model.isLoadingPullRequests { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for pull request list")
    }

    private func waitForPullRequestReviewSummary(_ model: AppModel) async {
        for _ in 0..<60 {
            if !model.isLoadingPullRequestReviewSummary { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for pull request review summary")
    }

    private func waitForPullRequestInlineReply(_ model: AppModel) async {
        for _ in 0..<60 {
            if !model.isPostingPullRequestInlineReply { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for pull request inline reply")
    }

    private func waitForPullRequestInlineComment(_ model: AppModel) async {
        for _ in 0..<60 {
            if !model.isPostingPullRequestInlineComment { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for pull request inline comment")
    }

    private func waitForPullRequestReviewSubmission(_ model: AppModel) async {
        for _ in 0..<60 {
            if !model.isSubmittingPullRequestReview { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for pull request review submission")
    }

    private func waitForRemoteSync(_ model: AppModel) async {
        for _ in 0..<80 {
            if !model.isSyncingRemote && !model.isLoading { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for remote sync")
    }

    private func waitForRemoteOperation(_ model: AppModel) async {
        for _ in 0..<80 {
            if !model.isRunningRemoteOperation && !model.isLoading { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for remote operation")
    }

    private func waitForLinkedWorktreeOperation(_ model: AppModel) async {
        for _ in 0..<80 {
            if !model.isRunningLinkedWorktreeOperation && !model.isLoading { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for linked worktree operation")
    }

    private func waitForSubmoduleOperation(_ model: AppModel) async {
        for _ in 0..<80 {
            if !model.isRunningSubmoduleOperation && !model.isLoading { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for submodule operation")
    }

    private func waitForBranchChange(_ model: AppModel) async {
        for _ in 0..<60 {
            if !model.isChangingBranch && !model.isLoading { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for branch change")
    }

    private func waitForBranchOperation(_ model: AppModel) async {
        for _ in 0..<80 {
            if !model.isRunningBranchOperation && !model.isLoading { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for branch operation")
    }

    private func waitForTagOperation(_ model: AppModel) async {
        for _ in 0..<60 {
            if !model.isRunningTagOperation && !model.isLoading { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for tag operation")
    }

    private func waitForWorktreeUpdate(_ model: AppModel) async {
        for _ in 0..<60 {
            if !model.isUpdatingWorktree && !model.isLoading { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for worktree update")
    }

    private func waitForWorktreeCommit(_ model: AppModel) async {
        for _ in 0..<80 {
            if !model.isCommittingWorktree && !model.isLoading { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for worktree commit")
    }

    private func waitForStashOperation(_ model: AppModel) async {
        for _ in 0..<80 {
            if !model.isRunningStashOperation && !model.isLoading { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for stash operation")
    }

    private func waitForHistorySearch(_ model: AppModel) async {
        for _ in 0..<60 {
            if !model.isSearchingHistory { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for history search")
    }

    private func waitForRewritePreview(_ model: AppModel) async {
        for _ in 0..<60 {
            if model.rewritePreview != nil { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for rewrite preview")
    }

    private func waitForBranchFlow(_ model: AppModel) async {
        for _ in 0..<60 {
            if model.branchFlow != nil { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for branch flow")
    }

    private func waitForPurgePreview(_ model: AppModel, path: String) async {
        for _ in 0..<60 {
            if !model.isLoadingPurgePreview && model.purgePreview?.paths == [path] { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for purge preview")
    }

    private func waitForSelectedDiff(_ model: AppModel, path: String) async {
        for _ in 0..<60 {
            if model.selectedFilePath == path && model.fileDiffs.contains(where: { $0.path == path }) { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for selected diff")
    }

    private func waitForSelectedBlame(_ model: AppModel, path: String) async {
        for _ in 0..<60 {
            if model.selectedFilePath == path && !model.fileBlame.isEmpty { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for selected blame")
    }

    private func makeRebaseConflict() throws -> URL {
        let remote = tmp.appendingPathComponent("remote-\(UUID().uuidString).git")
        try require(["init", "--bare", remote.path], in: tmp)
        let a = tmp.appendingPathComponent("a-\(UUID().uuidString)")
        let b = tmp.appendingPathComponent("b-\(UUID().uuidString)")
        try require(["clone", remote.path, a.path], in: tmp)
        try require(["clone", remote.path, b.path], in: tmp)
        try configureIdentity(a, name: "A")
        try configureIdentity(b, name: "B")

        try write("base\n", to: a, "conflict.txt")
        try commit("seed", repo: a)
        try require(["push", "-u", "origin", "HEAD"], in: a)
        try require(["pull"], in: b)

        try write("local\n", to: b, "conflict.txt")
        try commit("local edit", repo: b)

        try write("remote\n", to: a, "conflict.txt")
        try commit("remote edit", repo: a)
        try require(["push"], in: a)

        _ = try runner.run(["pull", "--rebase"], in: b)
        return b
    }

    private func makeSyncedRemotePair(prefix: String) throws -> (source: URL, repo: URL) {
        let remote = tmp.appendingPathComponent("\(prefix)-remote.git")
        try require(["init", "--bare", remote.path], in: tmp)
        let source = tmp.appendingPathComponent("\(prefix)-source")
        let repo = tmp.appendingPathComponent("\(prefix)-repo")
        try require(["clone", remote.path, source.path], in: tmp)
        try configureIdentity(source, name: "\(prefix) Source")
        try write("base\n", to: source, "base.txt")
        try commit("base", repo: source)
        try require(["push", "-u", "origin", "HEAD"], in: source)
        try require(["clone", remote.path, repo.path], in: tmp)
        try configureIdentity(repo, name: "\(prefix) Repo")
        return (source, repo)
    }

    @discardableResult
    private func require(_ args: [String], in repo: URL) throws -> GitCommandResult {
        let result = try runner.run(args, in: repo)
        XCTAssertTrue(result.succeeded, "git \(args.joined(separator: " ")) failed: \(result.standardError)")
        return result
    }
}

private final class PullRequestCapture: @unchecked Sendable {
    var draft: GitHubPullRequestDraft?
    var token: String?
}

private final class PullRequestListCapture: @unchecked Sendable {
    var repositoryFullName: String?
    var token: String?
}

private final class PullRequestReviewSummaryCapture: @unchecked Sendable {
    var repositoryFullName: String?
    var number: Int?
    var token: String?
}

private final class PullRequestInlineReplyCapture: @unchecked Sendable {
    var repositoryFullName: String?
    var number: Int?
    var commentID: Int?
    var body: String?
    var token: String?
}

private final class PullRequestInlineCommentCreateCapture: @unchecked Sendable {
    var repositoryFullName: String?
    var number: Int?
    var draft: GitHubPullRequestInlineCommentDraft?
    var token: String?
}

private final class PullRequestReviewSubmitCapture: @unchecked Sendable {
    var repositoryFullName: String?
    var number: Int?
    var event: GitHubPullRequestReviewEvent?
    var body: String?
    var token: String?
}

private final class ProviderOAuthCapture: @unchecked Sendable {
    var requestClientID: String?
    var waitClientID: String?
    var authorization: GitHubDeviceAuthorization?
    var loginToken: String?
}

private final class MockAIPontTransport: AIPontHTTPTransport, @unchecked Sendable {
    private let body: String

    init(body: String) {
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}
