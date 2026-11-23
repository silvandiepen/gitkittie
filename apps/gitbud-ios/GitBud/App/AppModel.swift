import Foundation
import GitKittieKit
import GitPontCore
import GitPontGitHub
import GitPontGitLab
import Observation

/// The app's one UI-facing state object. Everything reaches a git host through GitPont;
/// nothing here knows which host it is talking to beyond the connection it was given.
@MainActor
@Observable
final class AppModel {
    // MARK: Session

    var isRestoring = true
    var isConnecting = false
    var errorMessage: String?
    var statusMessage: String?
    private(set) var connection: ProviderConnection?
    private(set) var isDemo = false
    /// The GitHub sign-in code while the person authorises in a browser.
    var deviceAuth: GitOAuthDeviceSession?

    var isConnected: Bool { connection != nil }

    // MARK: Repositories

    private(set) var repositories: [GitRepository] = []
    private(set) var isLoadingRepositories = false
    /// The open repository, by `GitRepositoryReference` key.
    var selectedRepositoryKey: String? {
        didSet {
            guard selectedRepositoryKey != oldValue, !isOpeningInPlace else { return }
            Task { await openSelectedRepository() }
        }
    }
    /// Set while `openRepository(key:)` opens a repository itself, so the selection's own
    /// reaction does not load it a second time.
    @ObservationIgnored private var isOpeningInPlace = false
    var selectedRepository: GitRepository? {
        repositories.first { $0.reference.key == selectedRepositoryKey }
    }

    // MARK: Inside a repository

    private(set) var branches: [GitPontCore.GitBranch] = []
    private(set) var branch: String?
    private(set) var commits: [GitCommitSummary] = []
    private(set) var hasMoreCommits = false
    private(set) var isLoadingCommits = false
    private var commitPage = 1
    private(set) var pullRequests: [GitPullRequest] = []
    private(set) var isLoadingPullRequests = false
    var pullRequestFilter: GitPullRequestListQuery.Filter = .open {
        didSet { if pullRequestFilter != oldValue { Task { await loadPullRequests() } } }
    }
    /// The commit shown on the right, or pushed on iPhone.
    var selectedCommitSHA: String?
    private var details: [String: GitCommitDetail] = [:]

    // MARK: Dependencies

    @ObservationIgnored private let keychain = KeychainService(service: "app.hakobs.gitbud", account: "provider-token")
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let connectionKey = "gitbud.connection"
    @ObservationIgnored private let lastRepositoryKey = "gitbud.lastRepository"
    @ObservationIgnored private let magic = AIPontMagicService()
    @ObservationIgnored private let gitHubOAuth = OAuthAppConfig(clientID: "Ov23li24tWFt7qLuLqCe", scopes: ["repo"])

    private struct StoredConnection: Codable {
        let choice: ProviderChoice
        let serverURL: String?
    }

    // MARK: - Lifecycle

    func restore() async {
        defer { isRestoring = false }
        guard let data = defaults.data(forKey: connectionKey),
              let stored = try? JSONDecoder().decode(StoredConnection.self, from: data),
              let token = ((try? keychain.load()) ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return }
        await connect(choice: stored.choice, serverURL: stored.serverURL, token: token, persist: false)
        if let last = defaults.string(forKey: lastRepositoryKey), repositories.contains(where: { $0.reference.key == last }) {
            await openRepository(key: last)
        }
    }

    /// The offline demo repository, no account needed.
    func loadDemo() async {
        isDemo = true
        connection = ProviderConnection(
            choice: nil, instance: .github, provider: DemoProvider(store: DemoStore()), token: "demo", login: "demo")
        await loadRepositories()
        if let first = repositories.first?.reference.key { await openRepository(key: first) }
    }

    /// Selects a repository and returns once its branches, history and pull requests are in.
    func openRepository(key: String) async {
        isOpeningInPlace = true
        selectedRepositoryKey = key
        isOpeningInPlace = false
        await openSelectedRepository()
    }

    // MARK: - Connect

    func connect(choice: ProviderChoice, serverURL rawServerURL: String?, token rawToken: String, persist: Bool = true) async {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { errorMessage = "Enter a personal access token."; return }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        let instance: GitProviderInstance
        let provider: any GitProvider
        switch choice {
        case .github:
            instance = .github
            provider = GitHubProvider(httpClient: URLSessionHTTPClient())
        case .gitlabCloud:
            instance = .gitLabCloud
            provider = GitLabProvider(httpClient: URLSessionHTTPClient(), instances: [.gitLabCloud])
        case .gitlabSelfHosted:
            guard let raw = rawServerURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
                  let url = URL(string: raw.hasPrefix("http") ? raw : "https://\(raw)") else {
                errorMessage = "Enter the address of your GitLab server."
                return
            }
            instance = .gitLabSelfHosted(baseURL: url)
            provider = GitLabProvider(httpClient: URLSessionHTTPClient(), instances: [instance])
        }
        await establish(choice: choice, instance: instance, provider: provider, token: token, serverURL: rawServerURL, persist: persist)
    }

    private func establish(choice: ProviderChoice, instance: GitProviderInstance, provider: any GitProvider, token: String, serverURL: String?, persist: Bool) async {
        do {
            let account = try await provider.account(instance: instance, credential: GitCredential(accessToken: token))
            connection = ProviderConnection(choice: choice, instance: instance, provider: provider, token: token, login: account.login)
            isDemo = false
            if persist {
                try keychain.save(token)
                if let data = try? JSONEncoder().encode(StoredConnection(choice: choice, serverURL: serverURL)) {
                    defaults.set(data, forKey: connectionKey)
                }
            }
            await loadRepositories()
        } catch {
            errorMessage = "Could not connect: \(error.localizedDescription)"
        }
    }

    /// GitHub sign-in with the device flow: a code to enter in the browser, then wait.
    func startGitHubSignIn() async {
        errorMessage = nil
        isConnecting = true
        let provider = GitHubProvider(httpClient: URLSessionHTTPClient(), oauth: gitHubOAuth)
        do {
            let result = try await provider.startOAuth(GitOAuthStartRequest(instance: .github, method: .oauthDevice, appConfig: gitHubOAuth))
            guard case let .device(session) = result else {
                finishSignIn(error: "GitHub answered in a way GitKittie Bud did not expect.")
                return
            }
            deviceAuth = session
            await pollGitHubSignIn(provider: provider, session: session)
        } catch {
            finishSignIn(error: "Could not start sign-in: \(error.localizedDescription)")
        }
    }

    func cancelSignIn() {
        deviceAuth = nil
        isConnecting = false
    }

    private func pollGitHubSignIn(provider: GitHubProvider, session: GitOAuthDeviceSession) async {
        var interval = max(session.interval, 5)
        while Date() < session.expiresAt {
            try? await Task.sleep(for: .seconds(interval))
            if deviceAuth == nil { return } // cancelled
            do {
                let credential = try await provider.completeOAuth(GitOAuthCompletionRequest(
                    instance: .github, method: .oauthDevice, appConfig: gitHubOAuth, deviceCode: session.deviceCode))
                deviceAuth = nil
                await establish(choice: .github, instance: .github, provider: provider, token: credential.accessToken, serverURL: nil, persist: true)
                isConnecting = false
                return
            } catch GitPontError.authenticationFailed(let message) {
                let text = message.lowercased()
                if text.contains("slow") { interval += 5 }
                if text.contains("denied") || text.contains("declined") { finishSignIn(error: "Sign-in was declined on GitHub."); return }
                if text.contains("expired") { finishSignIn(error: "The code expired. Try again."); return }
            } catch {
                continue // a network blip; keep waiting
            }
        }
        finishSignIn(error: "Sign-in timed out. Try again.")
    }

    private func finishSignIn(error: String) {
        deviceAuth = nil
        isConnecting = false
        errorMessage = error
    }

    func signOut() {
        if !isDemo {
            try? keychain.delete()
            defaults.removeObject(forKey: connectionKey)
            defaults.removeObject(forKey: lastRepositoryKey)
        }
        connection = nil
        isDemo = false
        repositories = []
        selectedRepositoryKey = nil
        clearRepositoryState()
    }

    // MARK: - Repositories

    func loadRepositories() async {
        guard let connection else { return }
        isLoadingRepositories = true
        defer { isLoadingRepositories = false }
        do {
            let list = try await connection.provider.repositories(context: connection.context)
            repositories = list.items.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        } catch {
            errorMessage = "Could not load your repositories: \(error.localizedDescription)"
        }
    }

    private func clearRepositoryState() {
        branches = []
        branch = nil
        commits = []
        hasMoreCommits = false
        pullRequests = []
        selectedCommitSHA = nil
        details = [:]
    }

    private func openSelectedRepository() async {
        clearRepositoryState()
        guard let repository = selectedRepository, let connection else { return }
        if !isDemo { defaults.set(repository.reference.key, forKey: lastRepositoryKey) }
        do {
            branches = try await connection.provider.branches(repository: repository.reference, context: connection.context).items
                .sorted { $0.isDefault != $1.isDefault ? $0.isDefault : $0.name < $1.name }
        } catch {
            errorMessage = "Could not load branches: \(error.localizedDescription)"
        }
        branch = repository.reference.defaultBranch ?? branches.first(where: \.isDefault)?.name ?? branches.first?.name
        async let history: Void = loadCommits(reset: true)
        async let pulls: Void = loadPullRequests()
        _ = await (history, pulls)
    }

    func selectBranch(_ name: String) async {
        guard name != branch else { return }
        branch = name
        selectedCommitSHA = nil
        await loadCommits(reset: true)
    }

    /// The first page, or the next one.
    func loadCommits(reset: Bool) async {
        guard let repository = selectedRepository, let connection, !isLoadingCommits else { return }
        isLoadingCommits = true
        defer { isLoadingCommits = false }
        if reset {
            commitPage = 1
            commits = []
        }
        do {
            let page = try await connection.provider.commits(
                GitCommitHistoryQuery(repository: repository.reference, ref: branch, page: commitPage, perPage: 40),
                context: connection.context)
            commits += page.items.filter { new in !commits.contains { $0.sha == new.sha } }
            hasMoreCommits = page.truncated
            commitPage += 1
        } catch {
            errorMessage = "Could not load history: \(error.localizedDescription)"
        }
    }

    func loadPullRequests() async {
        guard let repository = selectedRepository, let connection else { return }
        isLoadingPullRequests = true
        defer { isLoadingPullRequests = false }
        do {
            pullRequests = try await connection.provider.pullRequests(
                GitPullRequestListQuery(repository: repository.reference, filter: pullRequestFilter),
                context: connection.context).items
        } catch {
            errorMessage = "Could not load \(connection.changeRequestName)s: \(error.localizedDescription)"
        }
    }

    /// One commit with its files, read once and kept for the session.
    func detail(of sha: String) async throws -> GitCommitDetail {
        if let cached = details[sha] { return cached }
        guard let repository = selectedRepository, let connection else { throw GitPontError.authenticationRequired }
        let detail = try await connection.provider.commit(sha: sha, repository: repository.reference, context: connection.context)
        details[sha] = detail
        return detail
    }

    /// A file's text at a commit, for the Full File view; nil when the file is not there.
    func text(of path: String, at ref: String) async throws -> String? {
        guard let repository = selectedRepository, let connection else { return nil }
        do {
            let file = try await connection.provider.readFile(
                GitFileReference(repository: repository.reference, path: path, ref: ref), context: connection.context)
            return String(decoding: file.content, as: UTF8.self)
        } catch GitPontError.notFound {
            return nil
        }
    }

    // MARK: - Chosen lines → pull request

    var canWrite: Bool {
        connection?.provider.capabilities.isSuperset(of: [.branchCreate, .batchCommit, .pullRequestCreate]) == true
            && selectedRepository?.permissions.canPush == true
    }

    /// Opens a pull request that picks (or undoes) the chosen lines of a commit.
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
        guard let repository = selectedRepository, let connection else { throw GitPontError.authenticationRequired }
        let composer = ChangeComposer(provider: connection.provider, context: connection.context, repository: repository.reference)
        let pull = try await composer.openPullRequest(
            commit: commit, diffs: diffs, selection: selection, reverse: reverse,
            target: target, branchName: branchName, title: title, body: body)
        statusMessage = "Opened \(connection.changeRequestName) #\(pull.number.map(String.init) ?? pull.id)."
        if let branches = try? await connection.provider.branches(repository: repository.reference, context: connection.context) {
            self.branches = branches.items.sorted { $0.isDefault != $1.isDefault ? $0.isDefault : $0.name < $1.name }
        }
        await loadPullRequests()
        return pull
    }

    // MARK: - On-device Magic

    /// Why Apple's on-device model can't draft here, or nil when it can.
    var magicUnavailableReason: String? { OnDeviceAI.unavailableReason }

    /// A title and description for the pull request, drafted on this device from the chosen
    /// lines. Nothing leaves the device; the person edits the result before using it.
    func draftPullRequest(commit: GitCommitDetail, diffs: [GitFileDiff], selection: GitChangeSelection, reverse: Bool) async throws -> (title: String, body: String) {
        let patch = GitPatchBuilder.patch(for: diffs, selection: selection, reverse: reverse)
        let intent = reverse ? "Undo part of the commit" : "Bring part of the commit to another branch"
        let text = try await magic.draftCommitMessage(
            configuration: AIPontMagicConfiguration(provider: .onDevice, apiKey: "", model: ""),
            request: AIPontMagicRequest(subject: "\(intent): \(commit.summary.subject)", body: "", diff: patch))
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let title = lines.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? text
        let body = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (title, body)
    }
}

extension GitRepositoryReference {
    /// A stable key for selection and for remembering the last repository.
    var key: String { "\(instance.id)|\(namespace)/\(name)" }
}
