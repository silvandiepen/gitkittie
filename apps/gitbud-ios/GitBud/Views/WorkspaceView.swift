import GitPontCore
import SwiftUI

/// Repositories → a repository's history or pull requests → a commit. Three columns on iPad,
/// a stack on iPhone, from the same split view.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var model
    // History and the commit side by side wherever there is room; iPhone collapses it anyway.
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var updates = AppUpdates()

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            RepositoryList(updates: updates)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } content: {
            if model.selectedRepository != nil {
                RepositoryScreen()
                    .navigationSplitViewColumnWidth(min: 300, ideal: 380)
            } else {
                ContentUnavailableView("Choose a repository", systemImage: "folder", description: Text("Its history and pull requests show here."))
                    .background(Theme.window)
            }
        } detail: {
            // The commit owns the stack its files push onto.
            if let sha = model.selectedCommitSHA {
                CommitScreen(sha: sha)
                    .id(sha)
            } else {
                ContentUnavailableView("Choose a commit", systemImage: "point.3.filled.connected.trianglepath.dotted", description: Text("Its message, files and changes show here."))
                    .background(Theme.window)
            }
        }
        .checksForAppUpdates(updates)
    }
}

/// The repositories of the connected account, newest activity first.
struct RepositoryList: View {
    let updates: AppUpdates
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedRepositoryKey) {
            Section {
                ForEach(shown, id: \.reference.key) { repository in
                    HStack(spacing: 10) {
                        Image(systemName: repository.isPrivate ? "lock.fill" : "book.closed")
                            .font(.body)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(repository.reference.name)
                                .font(.body.weight(.medium))
                            Text(repository.reference.namespace)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(repository.reference.key)
                }
            } header: {
                if model.isDemo { Text("Demo") }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebar.ignoresSafeArea())
        // A newer Bud in the App Store: Update opens its page there.
        .safeAreaInset(edge: .bottom) {
            if updates.offer != nil {
                UpdateAvailableNotice(updates: updates).padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .overlay {
            if model.isLoadingRepositories, model.repositories.isEmpty { ProgressView() }
        }
        .searchable(text: $search, prompt: "Repositories")
        .refreshable { await model.loadRepositories() }
        .navigationTitle("Repositories")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let login = model.connection?.login, !model.isDemo {
                        Text("Signed in as \(login)")
                    }
                    Button(model.isDemo ? "Leave the Demo" : "Sign Out", role: .destructive) { model.signOut() }
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .accessibilityLabel("Account")
            }
        }
    }

    private var shown: [GitRepository] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.repositories }
        return model.repositories.filter {
            "\($0.reference.namespace)/\($0.reference.name)".localizedCaseInsensitiveContains(query)
        }
    }
}

/// One repository: its history on a branch, or its pull requests.
struct RepositoryScreen: View {
    enum Section: String, CaseIterable, Identifiable {
        case history = "History"
        case pullRequests = "Pull Requests"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var section: Section = .history
    @State private var openPullRequest: GitPullRequest?

    var body: some View {
        @Bindable var model = model
        Group {
            switch section {
            case .history: history
            case .pullRequests: pullRequests
            }
        }
        .background(Theme.window)
        .navigationTitle(model.selectedRepository?.reference.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Show", selection: $section) {
                ForEach(Section.allCases) { Text(title(for: $0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.window)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { branchMenu }
        }
        .sheet(item: $openPullRequest) { PullRequestSheet(pullRequest: $0) }
    }

    private func title(for section: Section) -> String {
        section == .pullRequests && model.connection?.changeRequestName == "merge request" ? "Merge Requests" : section.rawValue
    }

    private var branchMenu: some View {
        Menu {
            ForEach(model.branches, id: \.name) { branch in
                Button {
                    Task { await model.selectBranch(branch.name) }
                } label: {
                    if branch.name == model.branch {
                        Label(branch.name, systemImage: "checkmark")
                    } else {
                        Text(branch.name)
                    }
                }
            }
        } label: {
            // Icon and name together: a toolbar label alone would drop the name.
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                Text(model.branch ?? "Branch").lineLimit(1)
            }
            .font(.callout.weight(.medium))
        }
        .accessibilityLabel("Branch \(model.branch ?? "")")
    }

    // MARK: History

    private var history: some View {
        @Bindable var model = model
        return List(selection: $model.selectedCommitSHA) {
            ForEach(model.commits) { commit in
                CommitRow(commit: commit)
                    .tag(commit.sha)
                    // The open commit is a tinted fill, never an outline or an edge bar.
                    .listRowBackground(model.selectedCommitSHA == commit.sha ? Color.accentColor.opacity(0.16) : Color.clear)
            }
            if model.hasMoreCommits {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .task { await model.loadCommits(reset: false) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if model.isLoadingCommits, model.commits.isEmpty { ProgressView() }
        }
        .refreshable { await model.loadCommits(reset: true) }
    }

    // MARK: Pull requests

    private var pullRequests: some View {
        @Bindable var model = model
        return List {
            Picker("Show", selection: $model.pullRequestFilter) {
                Text("Open").tag(GitPullRequestListQuery.Filter.open)
                Text("Closed").tag(GitPullRequestListQuery.Filter.closed)
                Text("All").tag(GitPullRequestListQuery.Filter.all)
            }
            .pickerStyle(.menu)
            .listRowBackground(Color.clear)

            ForEach(model.pullRequests, id: \.id) { pull in
                Button { openPullRequest = pull } label: { PullRequestRow(pullRequest: pull) }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
            }
            if model.pullRequests.isEmpty, !model.isLoadingPullRequests {
                Text("Nothing here.")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.loadPullRequests() }
    }
}

struct CommitRow: View {
    let commit: GitCommitSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if commit.isMerge {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.caption)
                        .foregroundStyle(.purple)
                        .accessibilityLabel("Merge")
                }
                Text(commit.subject)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Text(commit.shortSHA).monospaced()
                Text(commit.authorName)
                if let date = commit.authoredAt {
                    Text(date, format: .relative(presentation: .named))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

struct PullRequestRow: View {
    let pullRequest: GitPullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StateBadge(state: pullRequest.state, isDraft: pullRequest.isDraft)
                Text(pullRequest.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if let number = pullRequest.number { Text("#\(number)").monospacedDigit() }
                Text("\(pullRequest.sourceBranch) → \(pullRequest.targetBranch)")
                if let author = pullRequest.authorName { Text(author) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Open / Draft / Merged / Closed as a tinted capsule — a fill, never an outline.
struct StateBadge: View {
    let state: GitPullRequestState?
    let isDraft: Bool

    var body: some View {
        let (title, color): (String, Color) = {
            if isDraft { return ("Draft", .secondary) }
            switch state {
            case .open: return ("Open", .green)
            case .merged: return ("Merged", .purple)
            case .closed: return ("Closed", .red)
            case nil: return ("", .secondary)
            }
        }()
        if !title.isEmpty {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(color.opacity(0.16), in: Capsule())
        }
    }
}

/// A pull request's description and where it goes, with a way to the host's page.
struct PullRequestSheet: View {
    let pullRequest: GitPullRequest
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        StateBadge(state: pullRequest.state, isDraft: pullRequest.isDraft)
                        if let number = pullRequest.number { Text("#\(number)").foregroundStyle(.secondary) }
                    }
                    Text(pullRequest.title).font(.title2.weight(.semibold))
                    Label("\(pullRequest.sourceBranch) → \(pullRequest.targetBranch)", systemImage: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                    if let author = pullRequest.authorName {
                        Label(author, systemImage: "person").foregroundStyle(.secondary)
                    }
                    if let body = pullRequest.body, !body.isEmpty {
                        Text(body)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
                    }
                    Button {
                        openURL(pullRequest.webURL)
                    } label: {
                        Label("Open on \(pullRequest.providerName)", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.window.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

extension GitPullRequest: @retroactive Identifiable {}
