import AppKit
import Foundation
import GitKittieKit
import Observation

/// A way back from a rewrite. GitBud always cuts a safety branch before rewriting, so
/// undo is a reset to that ref rather than anything clever.
public struct GitBudRewriteUndo: Sendable, Equatable {
    public let safetyBranch: String
    public let summary: String

    public init(safetyBranch: String, summary: String) {
        self.safetyBranch = safetyBranch
        self.summary = summary
    }
}

/// The four surfaces GitBud offers. History is the commit graph, Changes is the working
/// copy, Branches is a flat list. Everything else is an action on a selected item, or a
/// preference — not a place you navigate to.
public enum GitBudWorkspaceMode: String, CaseIterable, Identifiable {
    case history
    case changes
    case branches
    case pullRequests

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .history: return "History"
        case .changes: return "Changes"
        case .branches: return "Branches"
        case .pullRequests: return "Pull Requests"
        }
    }

    public var icon: String {
        switch self {
        case .history: return "point.3.filled.connected.trianglepath.dotted"
        case .changes: return "list.bullet.rectangle"
        case .branches: return "arrow.triangle.branch"
        case .pullRequests: return "arrow.triangle.pull"
        }
    }
}

@MainActor
@Observable
public final class AppModel {
    public var repositoryURL: URL?
    public var workspaceMode: GitBudWorkspaceMode = .history
    public var repositoryName = "No repository"
    public var branchSummary: GitBranchSummary?
    public var branches: [GitBranch] = []
    public var tags: [GitTag] = []
    public var remotes: [GitRemote] = []
    public var selectedRemoteName: String?
    public var selectedBranchOperationTargetName: String?
    public var branchFlow: GitBranchFlow?
    public var commits: [GitCommitNode] = []
    public var focusedCommitID: String?
    public var historySearchText = ""
    public var historySearchMode: GitHistorySearchMode = .message
    public var historySearchResults: [GitCommitNode] = []
    public var historySearchDidRun = false
    public var changedFiles: [GitChangedFile] = []
    public var worktreeFiles: [GitWorktreeFile] = []
    public var selectedWorktreePaths = Set<String>()
    public var linkedWorktrees: [GitLinkedWorktree] = []
    public var selectedLinkedWorktreePath: String?
    public var submodules: [GitSubmodule] = []
    public var selectedSubmodulePath: String?
    public var stashes: [GitStashEntry] = []
    public var selectedStashID: String?
    public var reflogEntries: [GitReflogEntry] = []
    public var selectedReflogEntryID: String?
    public var fileDiffs: [GitFileDiff] = []
    public var conflicts: [GitFileConflict] = []
    public var activeConflictMode: GitRewriteConflictMode = .rebase
    public var conflictDrafts: [String: String] = [:]
    public var selectedFilePath: String?
    public var fileHistory: [CommitInfo] = []
    public var fileBlame: [GitBlameLine] = []
    public var purgePreview: GitPurgePreview?
    public var selectedCommitIDs: [String] = []
    public var rewritePreview: GitRewritePreview?
    public var safetyBranchName: String?
    /// How much history is currently fetched. Raised by `loadMoreHistory()`.
    public var historyLimit = 160
    public var isLoadingMoreHistory = false
    /// Set after a successful rewrite so the UI can offer a one-click way back.
    public var rewriteUndo: GitBudRewriteUndo?
    public var isUndoingRewrite = false
    public var selectedSplitPaths = Set<String>()
    public var selectedSplitHunkIDs = Set<String>()
    public var isLoading = false
    public var isSearchingHistory = false
    public var isRewriting = false
    public var isCloningRemote = false
    public var isLoadingRemoteRepositories = false
    public var isSyncingRemote = false
    public var isCreatingPullRequest = false
    public var isLoadingPullRequests = false
    public var isLoadingPullRequestReviewSummary = false
    public var isPostingPullRequestInlineReply = false
    public var isPostingPullRequestInlineComment = false
    public var isSubmittingPullRequestReview = false
    public var isConnectingProviderAccount = false
    public var isChangingBranch = false
    public var isRunningBranchOperation = false
    public var isRunningTagOperation = false
    public var isRunningRemoteOperation = false
    public var isRunningLinkedWorktreeOperation = false
    public var isRunningSubmoduleOperation = false
    public var isRunningStashOperation = false
    public var isUpdatingWorktree = false
    public var isCommittingWorktree = false
    public var isLoadingPurgePreview = false
    public var canForcePush = false
    public var isCurrentBranchProtected = false
    public var protectedBranchPatterns = GitProtectedBranchPolicy().patterns
    public var protectedBranchPatternsText = ""
    public var isDraftingMagic = false
    public var magicProvider: AIPontProvider = .openAICompatible
    public var magicAPIKey = ""
    public var magicModel = "gpt-4o-mini"
    public var magicEndpoint = "https://api.openai.com/v1/chat/completions"
    public var magicDraft = ""
    public var remoteURLString = ""
    public var remoteAccessToken = ""
    public var providerRepositories: [GitHubRepo] = []
    public var selectedProviderRepositoryID: String?
    public var providerPullRequests: [GitHubPullRequest] = []
    public var providerOAuthClientID = "Ov23li24tWFt7qLuLqCe"
    public var providerOAuthAuthorization: GitHubDeviceAuthorization?
    public var providerLogin: String?
    public var selectedProviderPullRequestNumber: Int?
    public var providerPullRequestReviewSummary: GitHubPullRequestReviewSummary?
    public var selectedProviderPullRequestFilePath: String?
    public var selectedProviderInlineCommentID: Int?
    public var providerInlineCommentDraft = ""
    public var providerInlineCommentLineText = ""
    public var providerInlineCommentSide = "RIGHT"
    public var providerInlineReplyDraft = ""
    public var providerReviewBody = ""
    public var providerSubmittedReview: GitHubPullRequestSubmittedReview?
    public var purgeConfirmationText = ""
    public var forcePushConfirmationText = ""
    public var pullRequestTitle = ""
    public var pullRequestBody = ""
    public var pullRequestBaseBranch = ""
    public var createdPullRequestURL: URL?
    public var newBranchName = ""
    public var renameBranchName = ""
    public var newTagName = ""
    public var selectedTagName: String?
    public var newRemoteName = ""
    public var newRemoteURLString = ""
    public var newLinkedWorktreePath = ""
    public var newLinkedWorktreeBranch = ""
    public var stashMessage = ""
    public var worktreeCommitMessage = ""
    public var statusMessage = "Open a local repository or connect a GitPont remote to begin."
    public var errorMessage: String?

    @ObservationIgnored private let gitHistory = ShellGitHistoryService()
    @ObservationIgnored private let gitEngine = ShellGitEngine()
    @ObservationIgnored private let magicService: AIPontMagicService
    @ObservationIgnored private let settingsStore: GitBudSettingsStore
    @ObservationIgnored private let managedRepositoryRoot: URL
    @ObservationIgnored private let providerRepositoryLister: @Sendable (String) async throws -> [GitHubRepo]
    @ObservationIgnored private let pullRequestCreator: @Sendable (GitHubPullRequestDraft, String) async throws -> GitHubPullRequest
    @ObservationIgnored private let pullRequestLister: @Sendable (String, String) async throws -> [GitHubPullRequest]
    @ObservationIgnored private let pullRequestReviewSummaryLoader: @Sendable (String, Int, String) async throws -> GitHubPullRequestReviewSummary
    @ObservationIgnored private let pullRequestInlineCommentReplier: @Sendable (String, Int, Int, String, String) async throws -> GitHubPullRequestInlineComment
    @ObservationIgnored private let pullRequestInlineCommentCreator: @Sendable (String, Int, GitHubPullRequestInlineCommentDraft, String) async throws -> GitHubPullRequestInlineComment
    @ObservationIgnored private let pullRequestReviewSubmitter: @Sendable (String, Int, GitHubPullRequestReviewEvent, String, String) async throws -> GitHubPullRequestSubmittedReview
    @ObservationIgnored private let providerOAuthAuthorizationRequester: @Sendable (String) async throws -> GitHubDeviceAuthorization
    @ObservationIgnored private let providerOAuthTokenWaiter: @Sendable (String, GitHubDeviceAuthorization) async throws -> String
    @ObservationIgnored private let providerLoginLoader: @Sendable (String) async throws -> String

    public init(
        magicService: AIPontMagicService = AIPontMagicService(),
        settingsStore: GitBudSettingsStore = GitBudSettingsStore(),
        managedRepositoryRoot: URL = AppModel.defaultManagedRepositoryRoot(),
        providerRepositoryLister: @escaping @Sendable (String) async throws -> [GitHubRepo] = { token in
            try await GitHubReposService(userAgent: "GitBud").listRepositories(token: token)
        },
        pullRequestCreator: @escaping @Sendable (GitHubPullRequestDraft, String) async throws -> GitHubPullRequest = { draft, token in
            try await GitHubPullRequestService(userAgent: "GitBud").createPullRequest(draft, token: token)
        },
        pullRequestLister: @escaping @Sendable (String, String) async throws -> [GitHubPullRequest] = { repositoryFullName, token in
            try await GitHubPullRequestService(userAgent: "GitBud").listPullRequests(
                repositoryFullName: repositoryFullName,
                token: token
            )
        },
        pullRequestReviewSummaryLoader: @escaping @Sendable (String, Int, String) async throws -> GitHubPullRequestReviewSummary = { repositoryFullName, number, token in
            try await GitHubPullRequestService(userAgent: "GitBud").pullRequestReviewSummary(
                repositoryFullName: repositoryFullName,
                number: number,
                token: token
            )
        },
        pullRequestInlineCommentReplier: @escaping @Sendable (String, Int, Int, String, String) async throws -> GitHubPullRequestInlineComment = { repositoryFullName, number, commentID, body, token in
            try await GitHubPullRequestService(userAgent: "GitBud").replyToPullRequestInlineComment(
                repositoryFullName: repositoryFullName,
                number: number,
                commentID: commentID,
                body: body,
                token: token
            )
        },
        pullRequestInlineCommentCreator: @escaping @Sendable (String, Int, GitHubPullRequestInlineCommentDraft, String) async throws -> GitHubPullRequestInlineComment = { repositoryFullName, number, draft, token in
            try await GitHubPullRequestService(userAgent: "GitBud").createPullRequestInlineComment(
                repositoryFullName: repositoryFullName,
                number: number,
                draft: draft,
                token: token
            )
        },
        pullRequestReviewSubmitter: @escaping @Sendable (String, Int, GitHubPullRequestReviewEvent, String, String) async throws -> GitHubPullRequestSubmittedReview = { repositoryFullName, number, event, body, token in
            try await GitHubPullRequestService(userAgent: "GitBud").submitPullRequestReview(
                repositoryFullName: repositoryFullName,
                number: number,
                event: event,
                body: body,
                token: token
            )
        },
        providerOAuthAuthorizationRequester: @escaping @Sendable (String) async throws -> GitHubDeviceAuthorization = { clientID in
            try await GitHubOAuthService(clientID: clientID, userAgent: "GitBud").requestDeviceAuthorization()
        },
        providerOAuthTokenWaiter: @escaping @Sendable (String, GitHubDeviceAuthorization) async throws -> String = { clientID, authorization in
            try await GitHubOAuthService(clientID: clientID, userAgent: "GitBud").waitForAccessToken(authorization: authorization)
        },
        providerLoginLoader: @escaping @Sendable (String) async throws -> String = { token in
            try await GitHubOAuthService(clientID: "", userAgent: "GitBud").loadViewerLogin(token: token)
        }
    ) {
        self.magicService = magicService
        self.settingsStore = settingsStore
        self.managedRepositoryRoot = managedRepositoryRoot
        self.providerRepositoryLister = providerRepositoryLister
        self.pullRequestCreator = pullRequestCreator
        self.pullRequestLister = pullRequestLister
        self.pullRequestReviewSummaryLoader = pullRequestReviewSummaryLoader
        self.pullRequestInlineCommentReplier = pullRequestInlineCommentReplier
        self.pullRequestInlineCommentCreator = pullRequestInlineCommentCreator
        self.pullRequestReviewSubmitter = pullRequestReviewSubmitter
        self.providerOAuthAuthorizationRequester = providerOAuthAuthorizationRequester
        self.providerOAuthTokenWaiter = providerOAuthTokenWaiter
        self.providerLoginLoader = providerLoginLoader
        let settings = settingsStore.loadMagicSettings()
        magicProvider = settings.provider
        magicAPIKey = settings.apiKey
        magicModel = settings.model
        magicEndpoint = settings.endpoint
        remoteAccessToken = settingsStore.loadProviderAccessToken()
        protectedBranchPatterns = settingsStore.loadProtectedBranchPatterns()
        protectedBranchPatternsText = protectedBranchPatterns.joined(separator: "\n")
    }

    public var selectedCommit: GitCommitNode? {
        commits.first { $0.id == focusedCommitID } ?? historySearchResults.first { $0.id == focusedCommitID }
    }

    public var hasHistorySearch: Bool {
        !historySearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var visibleCommits: [GitCommitNode] {
        historySearchDidRun ? historySearchResults : commits
    }

    /// The visible history, placed into lanes for the graph. Search results are a filtered
    /// set rather than a contiguous history, so their parent links are not drawn.
    public var graphRows: [GitGraphRow] {
        layoutCommitGraph(visibleCommits)
    }

    /// Whether there is more history behind the current window worth fetching.
    public var canLoadMoreHistory: Bool {
        !historySearchDidRun && commits.count >= historyLimit
    }

    /// The commit currently shown in the detail pane.
    public var focusedCommit: GitCommitNode? { selectedCommit }

    public var selectedDiff: GitFileDiff? {
        guard let selectedFilePath else { return fileDiffs.first }
        return fileDiffs.first { $0.path == selectedFilePath }
    }

    public var hasConflicts: Bool { !conflicts.isEmpty }

    public var conflictContinueButtonTitle: String {
        switch activeConflictMode {
        case .merge:
            return "Continue Merge"
        case .rebase:
            return "Continue Rebase"
        case .revert:
            return "Continue Revert"
        case .cherryPick:
            return "Continue Cherry-pick"
        case .stashPop:
            return "Finish Stash Pop"
        }
    }

    public var conflictAbortButtonTitle: String {
        switch activeConflictMode {
        case .merge:
            return "Abort Merge"
        case .rebase:
            return "Abort Rebase"
        case .revert:
            return "Abort Revert"
        case .cherryPick:
            return "Abort Cherry-pick"
        case .stashPop:
            return "Abort Stash Pop"
        }
    }

    public var selectedProviderRepository: GitHubRepo? {
        guard let selectedProviderRepositoryID else { return nil }
        return providerRepositories.first { $0.id == selectedProviderRepositoryID }
    }

    public var selectedProviderPullRequest: GitHubPullRequest? {
        guard let selectedProviderPullRequestNumber else { return nil }
        return providerPullRequests.first { $0.number == selectedProviderPullRequestNumber }
    }

    public var selectedProviderPullRequestFile: GitHubPullRequestFile? {
        guard let selectedProviderPullRequestFilePath else { return providerPullRequestReviewSummary?.files.first }
        return providerPullRequestReviewSummary?.files.first { $0.path == selectedProviderPullRequestFilePath }
    }

    public var selectedProviderPullRequestFileComments: [GitHubPullRequestInlineComment] {
        guard let selectedProviderPullRequestFile, let providerPullRequestReviewSummary else { return [] }
        return providerPullRequestReviewSummary.inlineComments(for: selectedProviderPullRequestFile)
    }

    public var selectedProviderInlineComment: GitHubPullRequestInlineComment? {
        guard let selectedProviderInlineCommentID else { return selectedProviderPullRequestFileComments.first }
        return selectedProviderPullRequestFileComments.first { $0.id == selectedProviderInlineCommentID }
    }

    public var purgeConfirmationPhrase: String {
        guard let selectedFilePath else { return "" }
        return "PURGE \(selectedFilePath)"
    }

    public var isPurgePreviewReady: Bool {
        purgePreview?.paths == [selectedFilePath].compactMap { $0 }
    }

    public var isPurgeConfirmed: Bool {
        isPurgePreviewReady &&
            !purgeConfirmationPhrase.isEmpty &&
            purgeConfirmationText.trimmingCharacters(in: .whitespacesAndNewlines) == purgeConfirmationPhrase
    }

    public var forcePushConfirmationPhrase: String {
        guard let branch = branchSummary?.currentBranch, !branch.isEmpty else { return "" }
        return "FORCE PUSH \(branch)"
    }

    public var isForcePushConfirmed: Bool {
        !forcePushConfirmationPhrase.isEmpty &&
            forcePushConfirmationText.trimmingCharacters(in: .whitespacesAndNewlines) == forcePushConfirmationPhrase
    }

    public func openRepositoryPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a git repository."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openRepository(url) }
    }

    public func openRepository(_ url: URL) async {
        repositoryURL = url
        repositoryName = url.lastPathComponent
        await reload()
    }

    public func cloneRemoteRepository() {
        let rawRemote = remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawRemote.isEmpty else { return }
        isCloningRemote = true
        errorMessage = nil
        Task {
            do {
                let remote = remoteURL(from: rawRemote)
                let destination = try managedCloneDestination(for: rawRemote)
                try await gitEngine.clone(remote, to: destination, auth: remoteAuth())
                statusMessage = "Remote cloned into GitBud."
                await openRepository(destination)
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Could not clone remote repository."
            }
            isCloningRemote = false
        }
    }

    public func requestProviderConnectionCode() {
        let clientID = providerOAuthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            statusMessage = "Enter a GitHub OAuth client ID before connecting."
            return
        }
        isConnectingProviderAccount = true
        errorMessage = nil
        Task {
            do {
                providerOAuthAuthorization = try await providerOAuthAuthorizationRequester(clientID)
                statusMessage = "Enter code \(providerOAuthAuthorization?.userCode ?? "") on GitHub."
            } catch {
                providerOAuthAuthorization = nil
                errorMessage = error.localizedDescription
                statusMessage = "Could not start provider connection."
            }
            isConnectingProviderAccount = false
        }
    }

    public func finishProviderConnection() {
        let clientID = providerOAuthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            statusMessage = "Enter a GitHub OAuth client ID before connecting."
            return
        }
        guard let authorization = providerOAuthAuthorization else {
            statusMessage = "Request a provider connection code first."
            return
        }
        isConnectingProviderAccount = true
        errorMessage = nil
        Task {
            do {
                let token = try await providerOAuthTokenWaiter(clientID, authorization)
                remoteAccessToken = token
                try settingsStore.saveProviderAccessToken(token)
                providerLogin = try? await providerLoginLoader(token)
                statusMessage = providerLogin.map { "Provider connected as \($0)." } ?? "Provider connected."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Could not finish provider connection."
            }
            isConnectingProviderAccount = false
        }
    }

    public func saveProviderAccessToken() {
        do {
            try settingsStore.saveProviderAccessToken(remoteAccessToken)
            statusMessage = remoteAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Provider token cleared." : "Provider token saved."
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not save provider token."
        }
    }

    public func clearProviderAccessToken() {
        do {
            try settingsStore.clearProviderAccessToken()
            remoteAccessToken = ""
            providerLogin = nil
            providerOAuthAuthorization = nil
            providerRepositories = []
            selectedProviderRepositoryID = nil
            providerPullRequests = []
            selectedProviderPullRequestNumber = nil
            providerPullRequestReviewSummary = nil
            selectedProviderPullRequestFilePath = nil
            selectedProviderInlineCommentID = nil
            providerInlineCommentDraft = ""
            providerInlineCommentLineText = ""
            providerInlineReplyDraft = ""
            providerReviewBody = ""
            providerSubmittedReview = nil
            statusMessage = "Provider token cleared."
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not clear provider token."
        }
    }

    public func loadProviderRepositories() {
        let token = remoteAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            statusMessage = "Enter a provider token to load repositories."
            return
        }
        isLoadingRemoteRepositories = true
        errorMessage = nil
        Task {
            do {
                let repositories = try await providerRepositoryLister(token)
                providerRepositories = repositories
                selectedProviderRepositoryID = repositories.first?.id
                providerPullRequests = []
                selectedProviderPullRequestNumber = nil
                providerPullRequestReviewSummary = nil
                selectedProviderPullRequestFilePath = nil
                selectedProviderInlineCommentID = nil
                providerInlineCommentDraft = ""
                providerInlineCommentLineText = ""
                providerInlineReplyDraft = ""
                providerReviewBody = ""
                providerSubmittedReview = nil
                if let first = repositories.first {
                    remoteURLString = first.cloneURL.absoluteString
                    pullRequestBaseBranch = first.defaultBranch
                }
                statusMessage = repositories.isEmpty ? "No provider repositories found." : "Loaded provider repositories."
            } catch {
                providerRepositories = []
                selectedProviderRepositoryID = nil
                providerPullRequests = []
                selectedProviderPullRequestNumber = nil
                providerPullRequestReviewSummary = nil
                selectedProviderPullRequestFilePath = nil
                selectedProviderInlineCommentID = nil
                providerInlineCommentDraft = ""
                providerInlineCommentLineText = ""
                providerInlineReplyDraft = ""
                providerReviewBody = ""
                providerSubmittedReview = nil
                errorMessage = error.localizedDescription
                statusMessage = "Could not load provider repositories."
            }
            isLoadingRemoteRepositories = false
        }
    }

    public func selectProviderRepository(_ repository: GitHubRepo) {
        selectedProviderRepositoryID = repository.id
        remoteURLString = repository.cloneURL.absoluteString
        pullRequestBaseBranch = repository.defaultBranch
        providerPullRequests = []
        selectedProviderPullRequestNumber = nil
        providerPullRequestReviewSummary = nil
        selectedProviderPullRequestFilePath = nil
        selectedProviderInlineCommentID = nil
        providerInlineCommentDraft = ""
        providerInlineCommentLineText = ""
        providerInlineReplyDraft = ""
        providerReviewBody = ""
        providerSubmittedReview = nil
    }

    public func cloneSelectedProviderRepository() {
        guard let repository = selectedProviderRepository else {
            statusMessage = "Select a provider repository to clone."
            return
        }
        remoteURLString = repository.cloneURL.absoluteString
        cloneRemoteRepository()
    }

    public func createDraftPullRequest() {
        let token = remoteAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            statusMessage = "Enter a provider token before creating a pull request."
            return
        }
        guard let repository = selectedProviderRepository else {
            statusMessage = "Select a provider repository before creating a pull request."
            return
        }
        guard let branch = branchSummary?.currentBranch, !branch.isEmpty else {
            statusMessage = "Open a branch before creating a pull request."
            return
        }
        let base = pullRequestBaseBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? repository.defaultBranch
            : pullRequestBaseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = pullRequestTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultPullRequestTitle(for: branch)
            : pullRequestTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = pullRequestBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultPullRequestBody(for: branch)
            : pullRequestBody.trimmingCharacters(in: .whitespacesAndNewlines)

        isCreatingPullRequest = true
        errorMessage = nil
        createdPullRequestURL = nil
        Task {
            do {
                let pullRequest = try await pullRequestCreator(
                    GitHubPullRequestDraft(
                        repositoryFullName: repository.fullName,
                        title: title,
                        body: body,
                        head: branch,
                        base: base,
                        draft: true
                    ),
                    token
                )
                pullRequestTitle = pullRequest.title
                pullRequestBaseBranch = pullRequest.base
                createdPullRequestURL = pullRequest.url
                statusMessage = "Draft pull request #\(pullRequest.number) created."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Could not create pull request."
            }
            isCreatingPullRequest = false
        }
    }

    public func loadProviderPullRequests() {
        let token = remoteAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            statusMessage = "Enter a provider token before loading pull requests."
            return
        }
        guard let repository = selectedProviderRepository else {
            statusMessage = "Select a provider repository before loading pull requests."
            return
        }

        isLoadingPullRequests = true
        errorMessage = nil
        Task {
            do {
                providerPullRequests = try await pullRequestLister(repository.fullName, token)
                syncSelectedProviderPullRequest()
                statusMessage = providerPullRequests.isEmpty ? "No open pull requests found." : "Loaded open pull requests."
            } catch {
                providerPullRequests = []
                selectedProviderPullRequestNumber = nil
                providerPullRequestReviewSummary = nil
                selectedProviderPullRequestFilePath = nil
                selectedProviderInlineCommentID = nil
                providerInlineCommentDraft = ""
                providerInlineCommentLineText = ""
                providerInlineReplyDraft = ""
                providerReviewBody = ""
                providerSubmittedReview = nil
                errorMessage = error.localizedDescription
                statusMessage = "Could not load pull requests."
            }
            isLoadingPullRequests = false
        }
    }

    public func selectProviderPullRequest(_ pullRequest: GitHubPullRequest) {
        selectedProviderPullRequestNumber = pullRequest.number
        providerPullRequestReviewSummary = nil
        selectedProviderPullRequestFilePath = nil
        selectedProviderInlineCommentID = nil
        providerInlineCommentDraft = ""
        providerInlineCommentLineText = ""
        providerInlineReplyDraft = ""
        providerReviewBody = ""
        providerSubmittedReview = nil
    }

    public func selectProviderPullRequestFile(_ file: GitHubPullRequestFile) {
        selectedProviderPullRequestFilePath = file.path
        selectedProviderInlineCommentID = nil
        providerInlineCommentDraft = ""
        providerInlineCommentLineText = ""
        providerInlineReplyDraft = ""
    }

    public func selectProviderInlineComment(_ comment: GitHubPullRequestInlineComment) {
        selectedProviderInlineCommentID = comment.id
        providerInlineReplyDraft = ""
    }

    public func loadSelectedProviderPullRequestReviewSummary() {
        let token = remoteAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            statusMessage = "Enter a provider token before loading pull request review state."
            return
        }
        guard let repository = selectedProviderRepository else {
            statusMessage = "Select a provider repository before loading pull request review state."
            return
        }
        guard let pullRequest = selectedProviderPullRequest else {
            statusMessage = "Select a pull request before loading review state."
            return
        }

        isLoadingPullRequestReviewSummary = true
        errorMessage = nil
        Task {
            do {
                providerPullRequestReviewSummary = try await pullRequestReviewSummaryLoader(
                    repository.fullName,
                    pullRequest.number,
                    token
                )
                syncSelectedProviderPullRequestFile()
                statusMessage = "Loaded pull request #\(pullRequest.number) review state."
            } catch {
                providerPullRequestReviewSummary = nil
                selectedProviderPullRequestFilePath = nil
                selectedProviderInlineCommentID = nil
                providerInlineCommentDraft = ""
                providerInlineCommentLineText = ""
                providerInlineReplyDraft = ""
                errorMessage = error.localizedDescription
                statusMessage = "Could not load pull request review state."
            }
            isLoadingPullRequestReviewSummary = false
        }
    }

    public func postProviderInlineComment() {
        let token = remoteAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            statusMessage = "Enter a provider token before posting a review comment."
            return
        }
        guard let repository = selectedProviderRepository else {
            statusMessage = "Select a provider repository before posting a review comment."
            return
        }
        guard let pullRequest = selectedProviderPullRequest else {
            statusMessage = "Select a pull request before posting a review comment."
            return
        }
        guard let file = selectedProviderPullRequestFile else {
            statusMessage = "Select a pull request file before posting a review comment."
            return
        }
        guard let commitID = providerPullRequestReviewSummary?.pullRequest.headSHA ?? pullRequest.headSHA else {
            statusMessage = "Load pull request review state before posting an inline comment."
            return
        }
        let body = providerInlineCommentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            statusMessage = "Write an inline comment before posting."
            return
        }
        guard let line = Int(providerInlineCommentLineText.trimmingCharacters(in: .whitespacesAndNewlines)), line > 0 else {
            statusMessage = "Enter a changed-file line number before posting an inline comment."
            return
        }
        let side = providerInlineCommentSide == "LEFT" ? "LEFT" : "RIGHT"
        let draft = GitHubPullRequestInlineCommentDraft(
            body: body,
            commitID: commitID,
            path: file.path,
            line: line,
            side: side
        )

        isPostingPullRequestInlineComment = true
        errorMessage = nil
        Task {
            do {
                let comment = try await pullRequestInlineCommentCreator(
                    repository.fullName,
                    pullRequest.number,
                    draft,
                    token
                )
                if var summary = providerPullRequestReviewSummary {
                    summary.inlineComments.append(comment)
                    providerPullRequestReviewSummary = summary
                }
                selectedProviderInlineCommentID = comment.id
                providerInlineCommentDraft = ""
                providerInlineCommentLineText = ""
                statusMessage = "Posted inline comment to pull request #\(pullRequest.number)."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Could not post inline review comment."
            }
            isPostingPullRequestInlineComment = false
        }
    }

    public func postProviderInlineCommentReply() {
        let token = remoteAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            statusMessage = "Enter a provider token before replying to a review comment."
            return
        }
        guard let repository = selectedProviderRepository else {
            statusMessage = "Select a provider repository before replying to a review comment."
            return
        }
        guard let pullRequest = selectedProviderPullRequest else {
            statusMessage = "Select a pull request before replying to a review comment."
            return
        }
        guard let comment = selectedProviderInlineComment else {
            statusMessage = "Select a review comment before replying."
            return
        }
        let body = providerInlineReplyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            statusMessage = "Write a reply before posting."
            return
        }

        isPostingPullRequestInlineReply = true
        errorMessage = nil
        Task {
            do {
                let reply = try await pullRequestInlineCommentReplier(
                    repository.fullName,
                    pullRequest.number,
                    comment.id,
                    body,
                    token
                )
                if var summary = providerPullRequestReviewSummary {
                    summary.inlineComments.append(reply)
                    providerPullRequestReviewSummary = summary
                }
                selectedProviderInlineCommentID = reply.id
                providerInlineReplyDraft = ""
                statusMessage = "Posted reply to pull request #\(pullRequest.number)."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Could not post review reply."
            }
            isPostingPullRequestInlineReply = false
        }
    }

    public func submitProviderPullRequestReview(_ event: GitHubPullRequestReviewEvent) {
        let token = remoteAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            statusMessage = "Enter a provider token before submitting a pull request review."
            return
        }
        guard let repository = selectedProviderRepository else {
            statusMessage = "Select a provider repository before submitting a pull request review."
            return
        }
        guard let pullRequest = selectedProviderPullRequest else {
            statusMessage = "Select a pull request before submitting a review."
            return
        }
        let body = providerReviewBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard event == .approve || !body.isEmpty else {
            statusMessage = "Write a review message before commenting or requesting changes."
            return
        }

        isSubmittingPullRequestReview = true
        errorMessage = nil
        Task {
            do {
                let review = try await pullRequestReviewSubmitter(
                    repository.fullName,
                    pullRequest.number,
                    event,
                    body,
                    token
                )
                providerSubmittedReview = review
                providerReviewBody = ""
                statusMessage = "Submitted \(providerReviewStatusName(event)) review for pull request #\(pullRequest.number)."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Could not submit pull request review."
            }
            isSubmittingPullRequestReview = false
        }
    }

    public func fetchRemote() {
        guard let repositoryURL else { return }
        isSyncingRemote = true
        errorMessage = nil
        Task {
            do {
                try await gitEngine.fetch(at: repositoryURL, auth: remoteAuth())
                await reload(statusMessage: "Fetched remote branches.")
            } catch {
                await reloadAfterFailure(error, statusMessage: "Fetch needs attention.")
            }
            isSyncingRemote = false
        }
    }

    public func pullCurrentBranchWithRebase() {
        guard let repositoryURL else { return }
        isSyncingRemote = true
        activeConflictMode = .rebase
        errorMessage = nil
        Task {
            do {
                let result = try await gitEngine.pullRebase(at: repositoryURL, auth: remoteAuth())
                if result.conflicts.isEmpty {
                    statusMessage = result.updated ? "Pulled remote changes with rebase." : "Already up to date."
                } else {
                    statusMessage = "Pull rebase has conflicts."
                }
                await reload(statusMessage: statusMessage)
            } catch {
                await reloadAfterFailure(error, statusMessage: "Pull rebase needs attention.")
            }
            isSyncingRemote = false
        }
    }

    public func pushCurrentBranch() {
        guard let repositoryURL else { return }
        isSyncingRemote = true
        errorMessage = nil
        Task {
            do {
                try await gitEngine.push(at: repositoryURL, auth: remoteAuth())
                await reload(statusMessage: "Pushed current branch.")
            } catch {
                await reloadAfterFailure(error, statusMessage: "Push needs attention.")
            }
            isSyncingRemote = false
        }
    }

    public func reload(statusMessage finalStatusMessage: String? = nil) async {
        guard let repositoryURL else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            branchSummary = try await gitHistory.branchSummary(at: repositoryURL)
            branches = try await gitHistory.branches(at: repositoryURL)
            tags = try await gitHistory.tags(at: repositoryURL)
            remotes = try await gitHistory.remotes(at: repositoryURL)
            linkedWorktrees = try await gitHistory.linkedWorktrees(at: repositoryURL)
            submodules = try await gitHistory.submodules(at: repositoryURL)
            stashes = try await gitHistory.stashes(at: repositoryURL)
            reflogEntries = try await gitHistory.reflogEntries(at: repositoryURL)
            syncBranchOperationTarget()
            syncSelectedTag()
            syncSelectedRemote()
            syncSelectedLinkedWorktree()
            syncSelectedSubmodule()
            syncSelectedStash()
            syncSelectedReflogEntry()
            await loadBranchFlow()
            worktreeFiles = try await gitHistory.worktreeFiles(at: repositoryURL)
            commits = try await gitHistory.commitGraph(at: repositoryURL, limit: historyLimit)
            conflicts = (try? await gitHistory.conflicts(at: repositoryURL)) ?? []
            syncConflictDrafts()
            refreshProtectedBranchState(
                forceWithLeaseReady: (try? await gitHistory.forceWithLeaseReadiness(at: repositoryURL)) ?? false
            )
            if focusedCommitID == nil || commits.contains(where: { $0.id == focusedCommitID }) == false {
                focusedCommitID = commits.first?.id
            }
            syncSelectedCommits()
            selectedWorktreePaths = selectedWorktreePaths.intersection(Set(worktreeFiles.map(\.path)))
            try await loadSelectedCommitDetails()
            await loadRewritePreview()
            statusMessage = finalStatusMessage ?? (conflicts.isEmpty ? "Repository loaded." : "Resolve conflicts before rewriting history.")
        } catch {
            errorMessage = error.localizedDescription
            canForcePush = false
            isCurrentBranchProtected = false
            branches = []
            tags = []
            remotes = []
            selectedTagName = nil
            selectedRemoteName = nil
            linkedWorktrees = []
            selectedLinkedWorktreePath = nil
            submodules = []
            selectedSubmodulePath = nil
            stashes = []
            selectedStashID = nil
            reflogEntries = []
            selectedReflogEntryID = nil
            selectedBranchOperationTargetName = nil
            branchFlow = nil
            worktreeFiles = []
            statusMessage = "Could not load repository."
        }
    }

    public var branchOperationTargets: [GitBranch] {
        branches.filter { $0.kind == .local && !$0.isCurrent }
    }

    public var selectedBranchOperationTarget: GitBranch? {
        guard let selectedBranchOperationTargetName else { return nil }
        return branchOperationTargets.first { $0.shortName == selectedBranchOperationTargetName }
    }

    public var selectedTag: GitTag? {
        guard let selectedTagName else { return nil }
        return tags.first { $0.name == selectedTagName }
    }

    public var selectedRemote: GitRemote? {
        guard let selectedRemoteName else { return nil }
        return remotes.first { $0.name == selectedRemoteName }
    }

    public var selectedLinkedWorktree: GitLinkedWorktree? {
        guard let selectedLinkedWorktreePath else { return nil }
        return linkedWorktrees.first { $0.path == selectedLinkedWorktreePath }
    }

    public var selectedSubmodule: GitSubmodule? {
        guard let selectedSubmodulePath else { return nil }
        return submodules.first { $0.path == selectedSubmodulePath }
    }

    public var selectedStash: GitStashEntry? {
        guard let selectedStashID else { return nil }
        return stashes.first { $0.id == selectedStashID }
    }

    public var selectedReflogEntry: GitReflogEntry? {
        guard let selectedReflogEntryID else { return nil }
        return reflogEntries.first { $0.id == selectedReflogEntryID }
    }

    public func selectBranchOperationTarget(_ branch: GitBranch) {
        guard branch.kind == .local && !branch.isCurrent else { return }
        selectedBranchOperationTargetName = branch.shortName
        renameBranchName = branch.shortName
        Task { await loadBranchFlow() }
    }

    public func mergeSelectedBranchIntoCurrent() {
        runBranchOperation(mode: .merge, verb: "Merged") { repo, branchName in
            try await self.gitHistory.mergeBranch(at: repo, name: branchName)
        }
    }

    public func renameSelectedBranch() {
        let newName = renameBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        runBranchMutation(successMessage: "Renamed branch.") { repo, branchName in
            try await self.gitHistory.renameBranch(at: repo, oldName: branchName, newName: newName)
            self.selectedBranchOperationTargetName = newName
            self.renameBranchName = newName
        }
    }

    public func deleteSelectedBranch() {
        runBranchMutation(successMessage: "Deleted branch.") { repo, branchName in
            try await self.gitHistory.deleteBranch(at: repo, name: branchName)
            if self.selectedBranchOperationTargetName == branchName {
                self.selectedBranchOperationTargetName = nil
                self.renameBranchName = ""
            }
        }
    }

    public func createTagFromSelectedCommit() {
        guard let focusedCommitID else { return }
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        runTagMutation(successMessage: "Created tag \(name).") { repo in
            try await self.gitHistory.createTag(at: repo, name: name, target: focusedCommitID)
            self.selectedTagName = name
            self.newTagName = ""
        }
    }

    public func deleteSelectedTag() {
        guard let selectedTag else { return }
        runTagMutation(successMessage: "Deleted tag \(selectedTag.name).") { repo in
            try await self.gitHistory.deleteTag(at: repo, name: selectedTag.name)
            if self.selectedTagName == selectedTag.name {
                self.selectedTagName = nil
            }
        }
    }

    public func addRemote() {
        let name = newRemoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = newRemoteURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !url.isEmpty else { return }
        runRemoteMutation(successMessage: "Added remote \(name).") { repo in
            try await self.gitHistory.addRemote(at: repo, name: name, url: url)
            self.selectedRemoteName = name
            self.newRemoteName = ""
            self.newRemoteURLString = ""
        }
    }

    public func removeSelectedRemote() {
        guard let selectedRemote else { return }
        runRemoteMutation(successMessage: "Removed remote \(selectedRemote.name).") { repo in
            try await self.gitHistory.removeRemote(at: repo, name: selectedRemote.name)
            if self.selectedRemoteName == selectedRemote.name {
                self.selectedRemoteName = nil
            }
        }
    }

    public func addLinkedWorktree() {
        let path = newLinkedWorktreePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = newLinkedWorktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !branch.isEmpty else { return }
        runLinkedWorktreeMutation(successMessage: "Created linked worktree \(branch).") { repo in
            try await self.gitHistory.addLinkedWorktree(at: repo, path: path, branchName: branch)
            self.selectedLinkedWorktreePath = path
            self.newLinkedWorktreePath = ""
            self.newLinkedWorktreeBranch = ""
        }
    }

    public func removeSelectedLinkedWorktree() {
        guard let selectedLinkedWorktree, !selectedLinkedWorktree.isCurrent else { return }
        runLinkedWorktreeMutation(successMessage: "Removed linked worktree.") { repo in
            try await self.gitHistory.removeLinkedWorktree(at: repo, path: selectedLinkedWorktree.path)
            if self.selectedLinkedWorktreePath == selectedLinkedWorktree.path {
                self.selectedLinkedWorktreePath = nil
            }
        }
    }

    public func updateAllSubmodules() {
        runSubmoduleMutation(successMessage: "Updated submodules.") { repo in
            try await self.gitHistory.updateSubmodules(at: repo)
        }
    }

    public func updateSelectedSubmodule() {
        guard let selectedSubmodule else { return }
        runSubmoduleMutation(successMessage: "Updated \(selectedSubmodule.path).") { repo in
            try await self.gitHistory.updateSubmodules(at: repo, paths: [selectedSubmodule.path])
        }
    }

    public func rebaseCurrentBranchOntoSelectedBranch() {
        runBranchOperation(mode: .rebase, verb: "Rebased onto") { repo, branchName in
            try await self.gitHistory.rebaseCurrentBranch(onto: branchName, at: repo)
        }
    }

    public func toggleWorktreePath(_ file: GitWorktreeFile) {
        if selectedWorktreePaths.contains(file.path) {
            selectedWorktreePaths.remove(file.path)
        } else {
            selectedWorktreePaths.insert(file.path)
        }
    }

    public func stageSelectedWorktreePaths() {
        updateWorktree("Staged selected paths.") { repo, paths in
            try await self.gitHistory.stagePaths(at: repo, paths: paths)
        }
    }

    public func unstageSelectedWorktreePaths() {
        updateWorktree("Unstaged selected paths.") { repo, paths in
            try await self.gitHistory.unstagePaths(at: repo, paths: paths)
        }
    }

    public func discardSelectedWorktreePaths() {
        updateWorktree("Discarded selected working tree changes.") { repo, paths in
            try await self.gitHistory.discardPaths(at: repo, paths: paths)
        }
    }

    public func saveStash() {
        let message = stashMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        runStashOperation(successMessage: "Saved stash.") { repo in
            try await self.gitHistory.saveStash(at: repo, message: message)
            self.stashMessage = ""
            self.selectedWorktreePaths.removeAll()
        }
    }

    public func saveSelectedWorktreePathsToStash() {
        let paths = Array(selectedWorktreePaths).sorted()
        guard !paths.isEmpty else { return }
        let message = stashMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        runStashOperation(successMessage: "Saved selected paths to stash.") { repo in
            try await self.gitHistory.saveStash(at: repo, message: message, paths: paths)
            self.stashMessage = ""
            self.selectedWorktreePaths.removeAll()
        }
    }

    public func applySelectedStash() {
        guard let selectedStash else { return }
        runStashOperation(successMessage: "Applied stash \(selectedStash.id).") { repo in
            try await self.gitHistory.applyStash(at: repo, id: selectedStash.id)
        }
    }

    public func popSelectedStash() {
        guard let repositoryURL, let selectedStash else { return }
        isRunningStashOperation = true
        activeConflictMode = .stashPop
        errorMessage = nil
        Task {
            do {
                let result = try await gitHistory.popStash(at: repositoryURL, id: selectedStash.id)
                conflicts = result.conflicts
                if result.completed {
                    if selectedStashID == selectedStash.id {
                        selectedStashID = nil
                    }
                    await reload(statusMessage: "Popped stash \(selectedStash.id).")
                } else {
                    syncConflictDrafts()
                    await reload(statusMessage: "Stash pop has conflicts.")
                }
            } catch {
                await reloadAfterFailure(error, statusMessage: "Stash pop needs attention.")
            }
            isRunningStashOperation = false
        }
    }

    public func createBranchFromSelectedStash() {
        guard let selectedStash else { return }
        let branchName = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branchName.isEmpty else { return }
        runStashOperation(successMessage: "Created branch \(branchName) from stash.") { repo in
            try await self.gitHistory.createBranchFromStash(
                at: repo,
                id: selectedStash.id,
                branchName: branchName
            )
            self.newBranchName = ""
            if self.selectedStashID == selectedStash.id {
                self.selectedStashID = nil
            }
        }
    }

    public func dropSelectedStash() {
        guard let selectedStash else { return }
        runStashOperation(successMessage: "Dropped stash \(selectedStash.id).") { repo in
            try await self.gitHistory.dropStash(at: repo, id: selectedStash.id)
            if self.selectedStashID == selectedStash.id {
                self.selectedStashID = nil
            }
        }
    }

    public func commitSelectedWorktreePaths() {
        guard let repositoryURL else { return }
        let paths = Array(selectedWorktreePaths).sorted()
        guard !paths.isEmpty else { return }
        let message = worktreeCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        isCommittingWorktree = true
        errorMessage = nil
        Task {
            do {
                try await gitEngine.commit(at: repositoryURL, message: message, paths: paths)
                worktreeCommitMessage = ""
                selectedWorktreePaths.removeAll()
                statusMessage = "Committed selected changes."
                await reload()
            } catch {
                await reloadAfterFailure(error, statusMessage: "Commit needs attention.")
            }
            isCommittingWorktree = false
        }
    }

    public func amendHeadWithSelectedWorktreePaths() {
        guard let repositoryURL else { return }
        let paths = Array(selectedWorktreePaths).sorted()
        guard !paths.isEmpty else { return }
        isCommittingWorktree = true
        errorMessage = nil
        Task {
            do {
                try await gitHistory.amendHeadWithPaths(at: repositoryURL, paths: paths)
                selectedWorktreePaths.removeAll()
                await reload(statusMessage: "Amended HEAD with selected changes.")
            } catch {
                await reloadAfterFailure(error, statusMessage: "Amend needs attention.")
            }
            isCommittingWorktree = false
        }
    }

    public func checkoutBranch(_ branch: GitBranch) {
        guard let repositoryURL else { return }
        if branch.kind == .local && branch.isCurrent { return }
        isChangingBranch = true
        errorMessage = nil
        Task {
            do {
                switch branch.kind {
                case .local:
                    try await gitHistory.checkoutBranch(at: repositoryURL, name: branch.shortName)
                case .remote:
                    try await gitHistory.checkoutRemoteBranch(at: repositoryURL, remoteName: branch.shortName)
                }
                focusedCommitID = nil
                selectedCommitIDs.removeAll()
                rewritePreview = nil
                statusMessage = branch.kind == .remote ? "Created local tracking branch for \(branch.shortName)." : "Switched to \(branch.shortName)."
                await reload()
            } catch {
                await reloadAfterFailure(error, statusMessage: "Could not switch branch.")
            }
            isChangingBranch = false
        }
    }

    public func createBranchFromSelectedCommit() {
        guard let repositoryURL else { return }
        let name = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let startPoint = focusedCommitID ?? "HEAD"
        isChangingBranch = true
        errorMessage = nil
        Task {
            do {
                try await gitHistory.createBranch(at: repositoryURL, name: name, startPoint: startPoint, checkout: true)
                newBranchName = ""
                focusedCommitID = nil
                selectedCommitIDs.removeAll()
                rewritePreview = nil
                statusMessage = "Created and switched to \(name)."
                await reload()
            } catch {
                await reloadAfterFailure(error, statusMessage: "Could not create branch.")
            }
            isChangingBranch = false
        }
    }

    /// A plain click: this commit becomes both the focus and the whole selection.
    public func selectCommit(_ commit: GitCommitNode) {
        focusedCommitID = commit.id
        selectedCommitIDs = [commit.id]
        selectedFilePath = nil
        rewritePreview = nil
        Task { try? await loadSelectedCommitDetails() }
    }

    public func searchHistory() {
        guard let repositoryURL else { return }
        let query = historySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            historySearchResults = []
            historySearchDidRun = false
            statusMessage = "Enter a history search query."
            return
        }
        isSearchingHistory = true
        errorMessage = nil
        Task {
            do {
                let results = try await gitHistory.searchCommits(
                    at: repositoryURL,
                    query: query,
                    mode: historySearchMode
                )
                historySearchResults = results
                historySearchDidRun = true
                if let first = results.first {
                    selectCommit(first)
                }
                statusMessage = results.isEmpty ? "No history matches found." : "Found \(results.count) history matches."
            } catch {
                historySearchResults = []
                historySearchDidRun = true
                errorMessage = error.localizedDescription
                statusMessage = "History search needs attention."
            }
            isSearchingHistory = false
        }
    }

    public func clearHistorySearch() {
        historySearchText = ""
        historySearchResults = []
        historySearchDidRun = false
        statusMessage = "History search cleared."
    }

    public func toggleCommitSelection(_ commit: GitCommitNode) {
        if selectedCommitIDs.contains(commit.id) {
            selectedCommitIDs.removeAll { $0 == commit.id }
        } else {
            // Adding re-derives graph order, so a fresh selection always reads newest-first.
            let selected = Set(selectedCommitIDs).union([commit.id])
            selectedCommitIDs = commits.filter { selected.contains($0.id) }.map(\.id)
        }
        Task { await loadRewritePreview() }
    }

    /// Selects everything between the focused commit and `commit` in graph order.
    public func extendCommitSelection(to commit: GitCommitNode) {
        let visible = visibleCommits.map(\.id)
        guard let anchorID = focusedCommitID ?? selectedCommitIDs.first,
              let anchor = visible.firstIndex(of: anchorID),
              let target = visible.firstIndex(of: commit.id)
        else {
            selectCommit(commit)
            return
        }
        let range = anchor <= target ? anchor...target : target...anchor
        selectedCommitIDs = Array(visible[range])
        focusedCommitID = commit.id
        Task {
            try? await loadSelectedCommitDetails()
            await loadRewritePreview()
        }
    }

    public func selectFile(_ file: GitChangedFile) {
        selectedFilePath = file.path
        fileHistory = []
        fileBlame = []
        purgePreview = nil
        purgeConfirmationText = ""
        Task {
            await loadFileHistory(file.path)
            await loadFileBlame(file.path)
            await loadPurgePreview(for: file.path)
        }
    }

    public func toggleSplitPath(_ file: GitChangedFile) {
        if selectedSplitPaths.contains(file.path) {
            selectedSplitPaths.remove(file.path)
        } else {
            selectedSplitPaths.insert(file.path)
        }
    }

    public func toggleSplitHunk(_ hunk: GitHunk) {
        if selectedSplitHunkIDs.contains(hunk.id) {
            selectedSplitHunkIDs.remove(hunk.id)
        } else {
            selectedSplitHunkIDs.insert(hunk.id)
        }
    }

    /// Fetches another page of history. The graph is a window onto `git log`, not the whole thing.
    public func loadMoreHistory() {
        guard let repositoryURL, !isLoadingMoreHistory, canLoadMoreHistory else { return }
        isLoadingMoreHistory = true
        Task {
            defer { isLoadingMoreHistory = false }
            historyLimit += 160
            do {
                commits = try await gitHistory.commitGraph(at: repositoryURL, limit: historyLimit)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Puts the branch back where it was before the last rewrite, using the safety ref
    /// GitBud cut automatically beforehand.
    public func undoLastRewrite() {
        guard let repositoryURL, let undo = rewriteUndo, !isUndoingRewrite else { return }
        isUndoingRewrite = true
        errorMessage = nil
        Task {
            defer { isUndoingRewrite = false }
            do {
                try await gitHistory.recoverCurrentBranchToCommit(at: repositoryURL, commit: undo.safetyBranch)
                rewriteUndo = nil
                safetyBranchName = nil
                await reload(statusMessage: "Undid: \(undo.summary)")
            } catch {
                await reloadAfterFailure(error, statusMessage: "Undo needs attention.")
            }
        }
    }

    public func dismissRewriteUndo() {
        rewriteUndo = nil
    }

    public func prepareSafetyBranch() {
        guard let repositoryURL else { return }
        Task {
            do {
                safetyBranchName = try await gitHistory.createSafetyBranch(at: repositoryURL)
                statusMessage = "Safety branch created: \(safetyBranchName ?? "")"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func squashSelectedCommits() {
        syncSelectedCommits()
        let count = selectedCommitIDs.count
        runRewrite("Squashed \(count) commits.") { repo in
            try await self.gitHistory.squashRecentCommits(
                at: repo,
                count: count,
                message: self.magicDraftMessage(fallback: self.suggestSquashMessage())
            )
        }
    }

    public func splitHeadCommitBySelectedFiles() {
        guard let focusedCommitID else { return }
        let paths = Array(selectedSplitPaths).sorted()
        guard !paths.isEmpty || !selectedSplitHunkIDs.isEmpty else {
            statusMessage = "Select at least one file or hunk before splitting a commit."
            return
        }
        runRewrite("Split selected commit into selected and remaining commits.") { repo in
            if self.selectedSplitHunkIDs.isEmpty {
                try await self.gitHistory.splitCommitByFiles(
                    at: repo,
                    commit: focusedCommitID,
                    paths: paths,
                    newCommitMessage: self.magicDraftMessage(fallback: "Split selected files"),
                    remainingCommitMessage: "Keep remaining changes"
                )
            } else {
                try await self.gitHistory.splitCommitByHunks(
                    at: repo,
                    commit: focusedCommitID,
                    hunkIDs: self.selectedSplitHunkIDs,
                    newCommitMessage: self.magicDraftMessage(fallback: "Split selected hunks"),
                    remainingCommitMessage: "Keep remaining changes"
                )
            }
        }
    }

    public func editHeadCommitMessage() {
        guard let selectedCommit else { return }
        let message = magicDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        runRewrite("Updated commit message.") { repo in
            try await self.gitHistory.editHeadCommitMessage(
                at: repo,
                message: message.isEmpty ? "Refine: \(selectedCommit.subject)" : message
            )
        }
    }

    public func draftMagicCommitMessage() {
        guard let selectedCommit else { return }
        isDraftingMagic = true
        errorMessage = nil
        Task {
            do {
                let endpoint = URL(string: magicEndpoint.trimmingCharacters(in: .whitespacesAndNewlines))
                magicDraft = try await magicService.draftCommitMessage(
                    configuration: AIPontMagicConfiguration(
                        provider: magicProvider,
                        apiKey: magicAPIKey,
                        model: magicModel,
                        endpoint: endpoint
                    ),
                    request: AIPontMagicRequest(
                        subject: selectedCommit.subject,
                        body: selectedCommit.body,
                        diff: magicDiffContext()
                    )
                )
                statusMessage = "Magic drafted a commit message."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Magic needs attention."
            }
            isDraftingMagic = false
        }
    }

    public func draftMagicRewriteMessage() {
        isDraftingMagic = true
        errorMessage = nil
        Task {
            do {
                let endpoint = URL(string: magicEndpoint.trimmingCharacters(in: .whitespacesAndNewlines))
                magicDraft = try await magicService.draftCommitMessage(
                    configuration: AIPontMagicConfiguration(
                        provider: magicProvider,
                        apiKey: magicAPIKey,
                        model: magicModel,
                        endpoint: endpoint
                    ),
                    request: AIPontMagicRequest(
                        subject: rewriteMagicSubject(),
                        body: rewriteMagicBody(),
                        diff: rewriteMagicDiffContext()
                    )
                )
                statusMessage = "Magic drafted a rewrite message."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Magic needs attention."
            }
            isDraftingMagic = false
        }
    }

    public func saveMagicSettings() {
        do {
            try settingsStore.saveMagicSettings(
                GitBudMagicSettings(
                    provider: magicProvider,
                    model: magicModel,
                    endpoint: magicEndpoint,
                    apiKey: magicAPIKey
                )
            )
            statusMessage = "Magic settings saved."
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not save Magic settings."
        }
    }

    public func saveProtectedBranchPolicy() {
        let patterns = parseProtectedBranchPatterns(protectedBranchPatternsText)
        let cleaned = patterns.isEmpty ? GitProtectedBranchPolicy().patterns : patterns
        protectedBranchPatterns = cleaned
        protectedBranchPatternsText = cleaned.joined(separator: "\n")
        settingsStore.saveProtectedBranchPatterns(cleaned)
        refreshProtectedBranchState()
        statusMessage = "Protected branch policy saved."
    }

    public func dropSelectedCommit() {
        guard let focusedCommitID else { return }
        runRewrite("Dropped selected commit.") { repo in
            try await self.gitHistory.dropCommit(at: repo, commit: focusedCommitID)
        }
    }

    public func resetCurrentBranchToSelectedCommit() {
        guard let repositoryURL, let focusedCommitID else { return }
        isRewriting = true
        errorMessage = nil
        Task {
            do {
                let backup = try await gitHistory.resetCurrentBranchToCommit(
                    at: repositoryURL,
                    commit: focusedCommitID
                )
                safetyBranchName = backup
                selectedCommitIDs.removeAll()
                rewritePreview = nil
                selectedSplitPaths.removeAll()
                selectedSplitHunkIDs.removeAll()
                await reload(statusMessage: "Reset current branch to selected commit.")
            } catch {
                await reloadAfterFailure(error, statusMessage: "Reset needs attention.")
            }
            isRewriting = false
        }
    }

    public func recoverCurrentBranchToSelectedReflogEntry() {
        guard let repositoryURL, let entry = selectedReflogEntry else { return }
        isRewriting = true
        errorMessage = nil
        Task {
            do {
                let backup = try await gitHistory.recoverCurrentBranch(to: entry, at: repositoryURL)
                safetyBranchName = backup
                selectedCommitIDs.removeAll()
                rewritePreview = nil
                selectedSplitPaths.removeAll()
                selectedSplitHunkIDs.removeAll()
                await reload(statusMessage: "Recovered current branch to \(entry.selector).")
            } catch {
                await reloadAfterFailure(error, statusMessage: "Recovery needs attention.")
            }
            isRewriting = false
        }
    }

    public func revertSelectedCommit() {
        guard let focusedCommitID else { return }
        activeConflictMode = .revert
        runRewriteOperation("Reverted selected commit.", conflictMessage: "Revert has conflicts.") { repo in
            try await self.gitHistory.revertCommit(at: repo, commit: focusedCommitID)
        }
    }

    public func cherryPickSelectedCommit() {
        guard let focusedCommitID else { return }
        activeConflictMode = .cherryPick
        runRewriteOperation("Cherry-picked selected commit.", conflictMessage: "Cherry-pick has conflicts.") { repo in
            try await self.gitHistory.cherryPickCommit(at: repo, commit: focusedCommitID)
        }
    }

    public func deleteSelectedFile() {
        guard let selectedFilePath else { return }
        runRewrite("Deleted \(selectedFilePath).") { repo in
            try await self.gitHistory.deleteFileAndCommit(
                at: repo,
                path: selectedFilePath,
                message: "Delete \(selectedFilePath)"
            )
        }
    }

    public func restoreSelectedFileFromSelectedCommit() {
        guard let repositoryURL, let focusedCommitID, let selectedFilePath else { return }
        isUpdatingWorktree = true
        errorMessage = nil
        Task {
            do {
                try await gitHistory.restorePaths(
                    at: repositoryURL,
                    paths: [selectedFilePath],
                    from: focusedCommitID
                )
                selectedWorktreePaths = [selectedFilePath]
                await reload(statusMessage: "Restored \(selectedFilePath) from selected commit.")
            } catch {
                await reloadAfterFailure(error, statusMessage: "Restore needs attention.")
            }
            isUpdatingWorktree = false
        }
    }

    public func purgeSelectedFileFromHistory() {
        guard let repositoryURL, let selectedFilePath else { return }
        guard isPurgePreviewReady else {
            statusMessage = "Load the purge preview before rewriting history."
            return
        }
        guard isPurgeConfirmed else {
            statusMessage = "Type \(purgeConfirmationPhrase) before purging history."
            return
        }
        isRewriting = true
        errorMessage = nil
        Task {
            do {
                let backup = try await gitHistory.purgePathsFromCurrentBranchHistory(
                    at: repositoryURL,
                    paths: [selectedFilePath]
                )
                safetyBranchName = backup
                selectedCommitIDs.removeAll()
                selectedSplitPaths.removeAll()
                selectedSplitHunkIDs.removeAll()
                purgePreview = nil
                purgeConfirmationText = ""
                statusMessage = "Purged \(selectedFilePath) from branch history."
                await reload()
            } catch {
                await reloadAfterFailure(error, statusMessage: "Purge needs attention.")
            }
            isRewriting = false
        }
    }

    public func pushRewrittenBranchWithLease() {
        guard let repositoryURL else { return }
        guard !isCurrentBranchProtected else {
            statusMessage = "Protected branches should use a new branch and draft PR."
            return
        }
        guard canForcePush else {
            statusMessage = "Force-with-lease is not ready for this branch."
            return
        }
        guard isForcePushConfirmed else {
            statusMessage = "Type \(forcePushConfirmationPhrase) before pushing rewritten history."
            return
        }
        isRewriting = true
        errorMessage = nil
        Task {
            do {
                try await gitHistory.pushForceWithLease(at: repositoryURL)
                forcePushConfirmationText = ""
                statusMessage = "Pushed rewritten branch with force-with-lease."
                await reload()
            } catch {
                await reloadAfterFailure(error, statusMessage: "Push needs attention.")
            }
            isRewriting = false
        }
    }

    public func moveFocusedCommitEarlier() {
        syncSelectedCommits()
        moveFocusedCommit(offset: -1)
    }

    public func moveFocusedCommitLater() {
        syncSelectedCommits()
        moveFocusedCommit(offset: 1)
    }

    public func applyPlannedCommitOrder() {
        syncSelectedCommits()
        let plannedNewestFirst = selectedCommitIDs
        runRewrite("Applied planned commit order.") { repo in
            try await self.gitHistory.reorderCommits(
                at: repo,
                oldestToNewest: Array(plannedNewestFirst.reversed())
            )
        }
    }

    public func reverseSelectedCommitOrder() {
        syncSelectedCommits()
        selectedCommitIDs.reverse()
        Task { await loadRewritePreview() }
        let selectedNewestFirst = selectedCommitIDs
        runRewrite("Reordered selected commits.") { repo in
            try await self.gitHistory.reorderCommits(
                at: repo,
                oldestToNewest: Array(selectedNewestFirst.reversed())
            )
        }
    }

    public func resolveConflict(_ conflict: GitFileConflict, taking resolution: GitRewriteResolution) {
        runRewrite("Resolved \(conflict.path) with \(resolution == .yourChange ? "Your change" : "REmote change").") { repo in
            try await self.gitHistory.resolveConflict(at: repo, path: conflict.path, taking: resolution, mode: self.activeConflictMode)
        }
    }

    public func resolveConflictWithDraft(_ conflict: GitFileConflict) {
        let content = conflictDrafts[conflict.path] ?? defaultConflictDraft(for: conflict)
        runRewrite("Resolved \(conflict.path) with edited content.") { repo in
            try await self.gitHistory.resolveConflict(at: repo, path: conflict.path, content: content)
        }
    }

    public func continueRebase() {
        let mode = activeConflictMode
        runRewrite(continueMessage(for: mode)) { repo in
            switch mode {
            case .merge:
                try await self.gitHistory.continueMerge(at: repo)
            case .rebase:
                try await self.gitHistory.continueRebase(at: repo)
            case .revert:
                try await self.gitHistory.continueRevert(at: repo)
            case .cherryPick:
                try await self.gitHistory.continueCherryPick(at: repo)
            case .stashPop:
                guard let selectedStash = self.selectedStash else { throw GitRewriteError.emptySelection }
                try await self.gitHistory.finishStashPop(at: repo, id: selectedStash.id)
                if self.selectedStashID == selectedStash.id {
                    self.selectedStashID = nil
                }
            }
        }
    }

    public func abortRebase() {
        let mode = activeConflictMode
        runRewrite(abortMessage(for: mode)) { repo in
            switch mode {
            case .merge:
                try await self.gitHistory.abortMerge(at: repo)
            case .rebase:
                try await self.gitHistory.abortRebase(at: repo)
            case .revert:
                try await self.gitHistory.abortRevert(at: repo)
            case .cherryPick:
                try await self.gitHistory.abortCherryPick(at: repo)
            case .stashPop:
                try await self.gitHistory.abortStashPop(at: repo)
            }
        }
    }

    public func magicSuggestionPreview() -> String {
        if !magicDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return magicDraft
        }
        guard let selectedCommit else { return "Select a commit to draft a message." }
        return """
        \(selectedCommit.subject)

        Explain why this change exists, what it touches, and any follow-up needed.
        """
    }

    private func loadSelectedCommitDetails() async throws {
        guard let repositoryURL, let focusedCommitID else {
            changedFiles = []
            fileDiffs = []
            fileHistory = []
            fileBlame = []
            return
        }
        async let files = gitHistory.changedFiles(at: repositoryURL, commit: focusedCommitID)
        async let diffs = gitHistory.diff(at: repositoryURL, commit: focusedCommitID)
        changedFiles = try await files
        fileDiffs = try await diffs
        if let firstPath = changedFiles.first?.path {
            let changedPaths = Set(changedFiles.map(\.path))
            let detailPath = selectedFilePath.flatMap { changedPaths.contains($0) ? $0 : nil } ?? firstPath
            selectedFilePath = detailPath
            fileHistory = []
            fileBlame = []
            purgePreview = nil
            await loadFileHistory(detailPath)
            await loadFileBlame(detailPath)
            await loadPurgePreview(for: detailPath)
        } else {
            fileHistory = []
            fileBlame = []
            purgePreview = nil
        }
        selectedSplitPaths = selectedSplitPaths.intersection(Set(changedFiles.map(\.path)))
        selectedSplitHunkIDs = selectedSplitHunkIDs.intersection(Set(fileDiffs.flatMap(\.hunks).map(\.id)))
    }

    private func loadFileHistory(_ path: String) async {
        guard let repositoryURL else { return }
        let history = (try? await gitEngine.fileHistory(at: repositoryURL, file: path, limit: 40)) ?? []
        guard selectedFilePath == path else { return }
        fileHistory = history
    }

    private func loadFileBlame(_ path: String) async {
        guard let repositoryURL else { return }
        let blame = (try? await gitHistory.blame(at: repositoryURL, path: path)) ?? []
        guard selectedFilePath == path else { return }
        fileBlame = blame
    }

    private func loadPurgePreview(for path: String) async {
        guard let repositoryURL else {
            purgePreview = nil
            return
        }
        isLoadingPurgePreview = true
        let preview = try? await gitHistory.purgePreview(at: repositoryURL, paths: [path])
        guard selectedFilePath == path else {
            isLoadingPurgePreview = false
            return
        }
        purgePreview = preview
        isLoadingPurgePreview = false
    }

    private func runRewrite(_ successMessage: String, operation: @escaping (URL) async throws -> Void) {
        guard let repositoryURL else { return }
        isRewriting = true
        errorMessage = nil
        Task {
            do {
                if safetyBranchName == nil {
                    safetyBranchName = try await gitHistory.createSafetyBranch(at: repositoryURL)
                }
                let safetyPoint = safetyBranchName
                try await operation(repositoryURL)
                selectedCommitIDs.removeAll()
                rewritePreview = nil
                selectedSplitPaths.removeAll()
                selectedSplitHunkIDs.removeAll()
                if let safetyPoint {
                    rewriteUndo = GitBudRewriteUndo(safetyBranch: safetyPoint, summary: successMessage)
                }
                await reload(statusMessage: successMessage)
            } catch {
                await reloadAfterFailure(error, statusMessage: "Rewrite needs attention.")
            }
            isRewriting = false
        }
    }

    private func runRewriteOperation(
        _ successMessage: String,
        conflictMessage: String,
        operation: @escaping (URL) async throws -> GitBranchOperationResult
    ) {
        guard let repositoryURL else { return }
        isRewriting = true
        errorMessage = nil
        Task {
            do {
                if safetyBranchName == nil {
                    safetyBranchName = try await gitHistory.createSafetyBranch(at: repositoryURL)
                }
                let result = try await operation(repositoryURL)
                conflicts = result.conflicts
                if result.completed {
                    selectedCommitIDs.removeAll()
                    rewritePreview = nil
                    selectedSplitPaths.removeAll()
                    selectedSplitHunkIDs.removeAll()
                    statusMessage = successMessage
                } else {
                    statusMessage = conflictMessage
                }
                await reload(statusMessage: statusMessage)
            } catch {
                await reloadAfterFailure(error, statusMessage: "Rewrite needs attention.")
            }
            isRewriting = false
        }
    }

    private func reloadAfterFailure(_ error: Error, statusMessage: String) async {
        await reload(statusMessage: statusMessage)
        errorMessage = error.localizedDescription
    }

    private func updateWorktree(_ successMessage: String, operation: @escaping (URL, [String]) async throws -> Void) {
        guard let repositoryURL else { return }
        let paths = Array(selectedWorktreePaths).sorted()
        guard !paths.isEmpty else { return }
        isUpdatingWorktree = true
        errorMessage = nil
        Task {
            do {
                try await operation(repositoryURL, paths)
                selectedWorktreePaths.removeAll()
                statusMessage = successMessage
                await reload()
            } catch {
                await reloadAfterFailure(error, statusMessage: "Working tree action needs attention.")
            }
            isUpdatingWorktree = false
        }
    }

    private func runStashOperation(
        successMessage: String,
        operation: @escaping (URL) async throws -> Void
    ) {
        guard let repositoryURL else { return }
        isRunningStashOperation = true
        errorMessage = nil
        Task {
            do {
                try await operation(repositoryURL)
                await reload(statusMessage: successMessage)
            } catch {
                await reloadAfterFailure(error, statusMessage: "Stash action needs attention.")
            }
            isRunningStashOperation = false
        }
    }

    private func syncConflictDrafts() {
        let paths = Set(conflicts.map(\.path))
        conflictDrafts = conflictDrafts.filter { paths.contains($0.key) }
        for conflict in conflicts where conflictDrafts[conflict.path] == nil {
            conflictDrafts[conflict.path] = defaultConflictDraft(for: conflict)
        }
    }

    private func defaultConflictDraft(for conflict: GitFileConflict) -> String {
        conflict.sections
            .flatMap(\.lines)
            .joined(separator: "\n")
            .appending(conflict.sections.flatMap(\.lines).isEmpty ? "" : "\n")
    }

    private func runBranchOperation(
        mode: GitRewriteConflictMode,
        verb: String,
        operation: @escaping (URL, String) async throws -> GitBranchOperationResult
    ) {
        guard let repositoryURL, let target = selectedBranchOperationTarget else { return }
        isRunningBranchOperation = true
        activeConflictMode = mode
        errorMessage = nil
        Task {
            do {
                let result = try await operation(repositoryURL, target.shortName)
                conflicts = result.conflicts
                if result.completed {
                    statusMessage = "\(verb) \(target.shortName)."
                } else {
                    statusMessage = "\(mode == .merge ? "Merge" : "Rebase") has conflicts."
                }
                await reload(statusMessage: statusMessage)
            } catch {
                statusMessage = "\(mode == .merge ? "Merge" : "Rebase") needs attention."
                await reloadAfterFailure(error, statusMessage: statusMessage)
            }
            isRunningBranchOperation = false
        }
    }

    private func runBranchMutation(
        successMessage: String,
        operation: @escaping (URL, String) async throws -> Void
    ) {
        guard let repositoryURL, let target = selectedBranchOperationTarget else { return }
        isRunningBranchOperation = true
        errorMessage = nil
        Task {
            do {
                try await operation(repositoryURL, target.shortName)
                statusMessage = successMessage
                await reload()
            } catch {
                await reloadAfterFailure(error, statusMessage: "Branch action needs attention.")
            }
            isRunningBranchOperation = false
        }
    }

    private func runTagMutation(
        successMessage: String,
        operation: @escaping (URL) async throws -> Void
    ) {
        guard let repositoryURL else { return }
        isRunningTagOperation = true
        errorMessage = nil
        Task {
            do {
                try await operation(repositoryURL)
                statusMessage = successMessage
                await reload()
            } catch {
                await reloadAfterFailure(error, statusMessage: "Tag action needs attention.")
            }
            isRunningTagOperation = false
        }
    }

    private func runRemoteMutation(
        successMessage: String,
        operation: @escaping (URL) async throws -> Void
    ) {
        guard let repositoryURL else { return }
        isRunningRemoteOperation = true
        errorMessage = nil
        Task {
            do {
                try await operation(repositoryURL)
                await reload(statusMessage: successMessage)
            } catch {
                await reloadAfterFailure(error, statusMessage: "Remote action needs attention.")
            }
            isRunningRemoteOperation = false
        }
    }

    private func runLinkedWorktreeMutation(
        successMessage: String,
        operation: @escaping (URL) async throws -> Void
    ) {
        guard let repositoryURL else { return }
        isRunningLinkedWorktreeOperation = true
        errorMessage = nil
        Task {
            do {
                try await operation(repositoryURL)
                await reload(statusMessage: successMessage)
            } catch {
                await reloadAfterFailure(error, statusMessage: "Linked worktree action needs attention.")
            }
            isRunningLinkedWorktreeOperation = false
        }
    }

    private func runSubmoduleMutation(
        successMessage: String,
        operation: @escaping (URL) async throws -> Void
    ) {
        guard let repositoryURL else { return }
        isRunningSubmoduleOperation = true
        errorMessage = nil
        Task {
            do {
                try await operation(repositoryURL)
                await reload(statusMessage: successMessage)
            } catch {
                await reloadAfterFailure(error, statusMessage: "Submodule action needs attention.")
            }
            isRunningSubmoduleOperation = false
        }
    }

    private func syncBranchOperationTarget() {
        let targets = branches.filter { $0.kind == .local && !$0.isCurrent }
        if let selectedBranchOperationTargetName,
           targets.contains(where: { $0.shortName == selectedBranchOperationTargetName }) {
            return
        }
        selectedBranchOperationTargetName = targets.first?.shortName
        renameBranchName = targets.first?.shortName ?? ""
    }

    private func syncSelectedTag() {
        if let selectedTagName,
           tags.contains(where: { $0.name == selectedTagName }) {
            return
        }
        selectedTagName = tags.first?.name
    }

    private func syncSelectedRemote() {
        if let selectedRemoteName,
           remotes.contains(where: { $0.name == selectedRemoteName }) {
            return
        }
        selectedRemoteName = remotes.first?.name
    }

    private func syncSelectedLinkedWorktree() {
        if let selectedLinkedWorktreePath,
           linkedWorktrees.contains(where: { $0.path == selectedLinkedWorktreePath }) {
            return
        }
        selectedLinkedWorktreePath = linkedWorktrees.first(where: { !$0.isCurrent })?.path ?? linkedWorktrees.first?.path
    }

    private func syncSelectedSubmodule() {
        if let selectedSubmodulePath,
           submodules.contains(where: { $0.path == selectedSubmodulePath }) {
            return
        }
        selectedSubmodulePath = submodules.first?.path
    }

    private func syncSelectedProviderPullRequest() {
        if let selectedProviderPullRequestNumber,
           providerPullRequests.contains(where: { $0.number == selectedProviderPullRequestNumber }) {
            if providerPullRequestReviewSummary?.pullRequest.number != selectedProviderPullRequestNumber {
                providerPullRequestReviewSummary = nil
                selectedProviderPullRequestFilePath = nil
                selectedProviderInlineCommentID = nil
                providerInlineCommentDraft = ""
                providerInlineCommentLineText = ""
            } else {
                syncSelectedProviderPullRequestFile()
            }
            return
        }
        selectedProviderPullRequestNumber = providerPullRequests.first?.number
        providerPullRequestReviewSummary = nil
        selectedProviderPullRequestFilePath = nil
        selectedProviderInlineCommentID = nil
        providerInlineCommentDraft = ""
        providerInlineCommentLineText = ""
    }

    private func syncSelectedProviderPullRequestFile() {
        guard let summary = providerPullRequestReviewSummary else {
            selectedProviderPullRequestFilePath = nil
            selectedProviderInlineCommentID = nil
            providerInlineCommentDraft = ""
            providerInlineCommentLineText = ""
            return
        }
        if let selectedProviderPullRequestFilePath,
           summary.files.contains(where: { $0.path == selectedProviderPullRequestFilePath }) {
            syncSelectedProviderInlineComment()
            return
        }
        selectedProviderPullRequestFilePath = summary.files.first?.path
        selectedProviderInlineCommentID = nil
        providerInlineCommentDraft = ""
        providerInlineCommentLineText = ""
        syncSelectedProviderInlineComment()
    }

    private func syncSelectedProviderInlineComment() {
        let comments = selectedProviderPullRequestFileComments
        if let selectedProviderInlineCommentID,
           comments.contains(where: { $0.id == selectedProviderInlineCommentID }) {
            return
        }
        selectedProviderInlineCommentID = comments.first?.id
    }

    private func syncSelectedStash() {
        if let selectedStashID,
           stashes.contains(where: { $0.id == selectedStashID }) {
            return
        }
        selectedStashID = stashes.first?.id
    }

    private func syncSelectedReflogEntry() {
        if let selectedReflogEntryID,
           reflogEntries.contains(where: { $0.id == selectedReflogEntryID }) {
            return
        }
        selectedReflogEntryID = reflogEntries.first?.id
    }

    private func loadBranchFlow() async {
        guard let repositoryURL, let selectedBranchOperationTargetName else {
            branchFlow = nil
            return
        }
        branchFlow = try? await gitHistory.branchFlow(at: repositoryURL, targetBranch: selectedBranchOperationTargetName)
    }

    private func suggestSquashMessage() -> String {
        let selected = commits.filter { selectedCommitIDs.contains($0.id) }
        guard let newest = selected.first else { return "Squash commits" }
        return "Squash: \(newest.subject)"
    }

    private func magicDraftMessage(fallback: String) -> String {
        let trimmed = magicDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func defaultPullRequestTitle(for branch: String) -> String {
        "Prepare \(branch)"
    }

    private func defaultPullRequestBody(for branch: String) -> String {
        var lines = [
            "Created from GitBud after local branch review.",
            "",
            "Branch: \(branch)"
        ]
        if let safetyBranchName {
            lines.append("Safety branch: \(safetyBranchName)")
        }
        if canForcePush {
            lines.append("Rewritten history was reviewed locally before publishing.")
        }
        return lines.joined(separator: "\n")
    }

    private func providerReviewStatusName(_ event: GitHubPullRequestReviewEvent) -> String {
        switch event {
        case .approve:
            return "approval"
        case .requestChanges:
            return "changes-requested"
        case .comment:
            return "comment"
        }
    }

    private func continueMessage(for mode: GitRewriteConflictMode) -> String {
        switch mode {
        case .merge:
            return "Continued merge."
        case .rebase:
            return "Continued rebase."
        case .revert:
            return "Continued revert."
        case .cherryPick:
            return "Continued cherry-pick."
        case .stashPop:
            return "Finished stash pop."
        }
    }

    private func abortMessage(for mode: GitRewriteConflictMode) -> String {
        switch mode {
        case .merge:
            return "Aborted merge."
        case .rebase:
            return "Aborted rebase."
        case .revert:
            return "Aborted revert."
        case .cherryPick:
            return "Aborted cherry-pick."
        case .stashPop:
            return "Aborted stash pop."
        }
    }

    private var protectedBranchPolicy: GitProtectedBranchPolicy {
        GitProtectedBranchPolicy(patterns: protectedBranchPatterns)
    }

    private func parseProtectedBranchPatterns(_ text: String) -> [String] {
        var seen = Set<String>()
        let separators = CharacterSet(charactersIn: ",\n")
        return text.components(separatedBy: separators).compactMap { rawPattern in
            let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty, !seen.contains(pattern) else { return nil }
            seen.insert(pattern)
            return pattern
        }
    }

    private func refreshProtectedBranchState(forceWithLeaseReady: Bool? = nil) {
        let protected = protectedBranchPolicy.protects(branchSummary?.currentBranch)
        isCurrentBranchProtected = protected
        let readiness = forceWithLeaseReady ?? (canForcePush || (branchSummary?.upstream != nil && worktreeFiles.isEmpty))
        canForcePush = readiness && !protected
    }

    private func moveFocusedCommit(offset: Int) {
        guard let focusedCommitID,
              let index = selectedCommitIDs.firstIndex(of: focusedCommitID) else { return }
        let newIndex = index + offset
        guard selectedCommitIDs.indices.contains(newIndex) else { return }
        selectedCommitIDs.swapAt(index, newIndex)
        Task { await loadRewritePreview() }
    }

    private func syncSelectedCommits() {
        // Drop anything the current history no longer contains, keeping the planned order.
        let known = Set(commits.map(\.id))
        selectedCommitIDs = selectedCommitIDs.filter { known.contains($0) }
        if selectedCommitIDs.isEmpty {
            rewritePreview = nil
        }
    }

    private func loadRewritePreview() async {
        guard let repositoryURL else {
            rewritePreview = nil
            return
        }
        let plannedNewestFirst = selectedCommitIDs
        guard plannedNewestFirst.count > 1 else {
            rewritePreview = nil
            return
        }
        rewritePreview = try? await gitHistory.rewritePreview(
            at: repositoryURL,
            oldestToNewest: Array(plannedNewestFirst.reversed())
        )
    }

    private func magicDiffContext() -> String {
        fileDiffs.map { diff in
            let hunks = diff.hunks.map { hunk in
                ([hunk.header] + hunk.lines).joined(separator: "\n")
            }.joined(separator: "\n")
            return "diff -- \(diff.path)\n\(hunks)"
        }.joined(separator: "\n\n")
    }

    private func rewriteMagicSubject() -> String {
        if selectedCommitIDs.count > 1 {
            return "Draft a squash commit message for \(selectedCommitIDs.count) selected commits."
        }
        if !selectedSplitHunkIDs.isEmpty {
            return "Draft a commit message for the selected hunks split from \(selectedCommit?.subject ?? "a commit")."
        }
        if !selectedSplitPaths.isEmpty {
            return "Draft a commit message for the selected files split from \(selectedCommit?.subject ?? "a commit")."
        }
        return selectedCommit?.subject ?? "Draft a rewrite commit message."
    }

    private func rewriteMagicBody() -> String {
        let selectedSubjects = commits
            .filter { selectedCommitIDs.contains($0.id) }
            .map { "- \($0.subject)" }
            .joined(separator: "\n")
        let splitPaths = selectedSplitPaths.sorted().map { "- \($0)" }.joined(separator: "\n")
        let splitHunks = selectedSplitHunkIDs.sorted().map { "- \($0)" }.joined(separator: "\n")
        return [
            selectedSubjects.isEmpty ? nil : "Selected commits:\n\(selectedSubjects)",
            splitPaths.isEmpty ? nil : "Selected files:\n\(splitPaths)",
            splitHunks.isEmpty ? nil : "Selected hunks:\n\(splitHunks)"
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")
    }

    private func rewriteMagicDiffContext() -> String {
        let selectedIDs = commits.filter { selectedCommitIDs.contains($0.id) }.map(\.id)
        if selectedIDs.count > 1 {
            return commits
                .filter { selectedCommitIDs.contains($0.id) }
                .map { "\($0.shortID) \($0.subject)" }
                .joined(separator: "\n")
        }

        if !selectedSplitHunkIDs.isEmpty {
            let selected = selectedSplitHunkIDs
            return fileDiffs.map { diff in
                let hunks = diff.hunks.filter { selected.contains($0.id) }.map { hunk in
                    ([hunk.header] + hunk.lines).joined(separator: "\n")
                }.joined(separator: "\n")
                return hunks.isEmpty ? "" : "diff -- \(diff.path)\n\(hunks)"
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        }

        if !selectedSplitPaths.isEmpty {
            let selected = selectedSplitPaths
            return fileDiffs.filter { selected.contains($0.path) }.map { diff in
                let hunks = diff.hunks.map { hunk in
                    ([hunk.header] + hunk.lines).joined(separator: "\n")
                }.joined(separator: "\n")
                return "diff -- \(diff.path)\n\(hunks)"
            }.joined(separator: "\n\n")
        }

        return magicDiffContext()
    }

    private func remoteURL(from rawRemote: String) -> URL {
        if let url = URL(string: rawRemote), url.scheme != nil {
            return url
        }
        return URL(fileURLWithPath: rawRemote)
    }

    private func remoteAuth() -> GitAuth {
        let token = remoteAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? .sshAgent : .httpsToken(username: "x-access-token", token: token)
    }

    private func managedCloneDestination(for rawRemote: String) throws -> URL {
        try FileManager.default.createDirectory(at: managedRepositoryRoot, withIntermediateDirectories: true)
        let name = remoteDisplayName(from: rawRemote)
        return managedRepositoryRoot.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))")
    }

    private func remoteDisplayName(from rawRemote: String) -> String {
        let trimmed = rawRemote.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let last = trimmed.split(separator: "/").last.map(String.init) ?? "repository"
        let withoutGit = last.hasSuffix(".git") ? String(last.dropLast(4)) : last
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = withoutGit.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let slug = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return slug.isEmpty ? "repository" : slug
    }

    nonisolated public static func defaultManagedRepositoryRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("GitBud/Repositories", isDirectory: true)
    }
}
