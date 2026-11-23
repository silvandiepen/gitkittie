import GitKittieKit
import GitKanbanKit
import GitPontCore
import SwiftUI
import UIKit

/// Top-level flow: restore → connect → pick a repo → board.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.isRestoring {
                    SplashView()
                } else if model.activeRepo != nil || model.isDemo {
                    BoardScreen()
                } else if !model.hasHome {
                    ConnectView()
                } else {
                    HomeView()
                }
            }
        }
        // Changes are sent in the background; this is where you see that they are.
        .overlay(alignment: .bottomTrailing) {
            SyncIndicator().padding(.trailing, 16).padding(.bottom, 12)
        }
    }
}

/// Clean splash screen shown while restoring session.
private struct SplashView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            TasksWordmark()

            ProgressView()
                .controlSize(.regular)
                .padding(.top, 8)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
    }
}

/// Provider-agnostic connect: pick GitHub, GitLab.com, or a self-hosted GitLab, and
/// paste a personal access token. A token works against any instance without
/// per-server OAuth registration.
private struct ConnectView: View {
    @Environment(AppModel.self) private var model

    @State private var choice: ProviderChoice = .github
    @State private var serverURL = ""
    @State private var token = ""
    /// Presents GitHub's device-flow page in an in-app Safari View Controller.
    @State private var showGitHubSignIn = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    TasksWordmark(markSize: 76, animated: false)
                    Text("Your kanban board is a git repo.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            if let device = model.deviceAuth {
                deviceCodeSection(device)
            } else {
                // First thing on the screen, before any sign-in option. Someone without a
                // GitHub account — an App Store reviewer included — otherwise hits the
                // sign-in wall and has no way past it. The demo is the full app on an
                // in-memory repo, not a preview, so it is worth saying so plainly.
                Section {
                    Button {
                        Task { await model.loadDemo() }
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                            Text("Open the demo board").fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } header: {
                    Text("No account?")
                } footer: {
                    Text("A sample board with every feature working — add, edit, move and delete cards, offline. No account, no sign-in.")
                }

                Section {
                    FolderServerPicker()
                } header: {
                    Text("Folder on your Mac")
                } footer: {
                    Text("Macs running the Tasks folder server show up here when you're on the same network. Once added, they keep working away from home over Tailscale. No git account needed.")
                }

                Section("Provider") {
                    Picker("Provider", selection: $choice) {
                        ForEach(ProviderChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    if choice.needsServerURL {
                        TextField("GitLab server URL (e.g. git.acme.com)", text: $serverURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                }

                if choice == .github {
                    Section {
                        Button {
                            Task { await model.startGitHubOAuth() }
                        } label: {
                            HStack {
                                Image(systemName: "person.badge.key.fill")
                                Text("Sign in with GitHub")
                                Spacer()
                                if model.isConnecting { ProgressView() }
                            }
                        }
                        .disabled(model.isConnecting)
                    } footer: {
                        Text("Authorise on github.com without leaving the app — no token to create.")
                    }
                }

                Section {
                    SecureField("Personal access token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await model.connect(choice: choice, serverURL: serverURL, token: token) }
                    } label: {
                        HStack {
                            Spacer()
                            if model.isConnecting && model.deviceAuth == nil { ProgressView() }
                            else { Text("Connect with Token").fontWeight(.semibold) }
                            Spacer()
                        }
                    }
                    .disabled(model.isConnecting || token.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text(choice == .github ? "Or use a token" : "Personal access token")
                } footer: {
                    Text("Create a token with repository read/write scope in your provider's settings.")
                }

            }

            if let error = model.errorMessage {
                Section { Text(error).font(.callout).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Connect")
        // Copy the code as soon as it arrives so it is ready to paste, but do not open
        // GitHub yet — the page asks for the code immediately, and opening it first puts
        // the code behind the browser the user needs it for. They open it themselves.
        // The session going back to nil means sign-in finished, expired, or was
        // cancelled — close the browser if it is still up.
        .onChange(of: model.deviceAuth?.userCode) { _, userCode in
            if let userCode {
                UIPasteboard.general.string = userCode
            } else {
                showGitHubSignIn = false
            }
        }
        .sheet(isPresented: $showGitHubSignIn) {
            if let device = model.deviceAuth {
                SafariView(url: device.verificationURI).ignoresSafeArea()
            }
        }
    }

    /// Device-flow UI: show the user code, open the verification page in-app, and wait.
    private func deviceCodeSection(_ device: GitOAuthDeviceSession) -> some View {
        Section("Sign in with GitHub") {
            VStack(spacing: 12) {
                Text("Copied. Open GitHub, paste this code, and confirm to authorise Tasks.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(device.userCode)
                    .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                HStack {
                    Button {
                        UIPasteboard.general.string = device.userCode
                    } label: { Label("Copy Code", systemImage: "doc.on.doc") }
                        .buttonStyle(.borderless)
                    Spacer()
                    Button {
                        showGitHubSignIn = true
                    } label: { Label("Open GitHub", systemImage: "safari") }
                        .buttonStyle(.borderedProminent)
                }

                HStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for authorisation…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .cancel) { model.cancelOAuth() }
                        .buttonStyle(.borderless)
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 4)
        }
    }
}

/// The home screen: added repos, each showing the boards you picked from it. Tap a
/// board to open it. Add a repo, then browse it to select boards. Saved locally.
private struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false
    @State private var showAddServer = false
    @State private var showConnect = false
    @State private var showAISettings = false
    @State private var showNotificationSettings = false
    @State private var browseRepo: AddedRepo?
    @State private var showReviews = false
    @Environment(\.scenePhase) private var scenePhase

    /// "N tasks · 2 In Progress · 5 In Review" for a board row (loads lazily from listings).
    private func boardSubtitle(_ repo: AddedRepo, _ board: SelectedBoard) -> String {
        guard let summary = model.boardSummary(repo, board.folder) else {
            return board.folder.isEmpty ? "Loading…" : board.folder
        }
        var parts = ["\(summary.total) task\(summary.total == 1 ? "" : "s")"]
        parts += summary.active.prefix(3).map { "\($0.count) \($0.name)" }
        return parts.joined(separator: " · ")
    }

    /// Cards that are new or moved lane since the board was last opened.
    private func changedCount(_ repo: AddedRepo, _ board: SelectedBoard) -> Int {
        model.boardSummary(repo, board.folder)?.changed ?? 0
    }

    @State private var showAllTasks = false
    @State private var searchAllTasks = false
    /// Repositories folded shut on the home screen, by id.
    @AppStorage("homeFoldedRepos") private var foldedRepos = ""

    /// What can be done with a repository: choose its boards, or take it off the phone.
    @ViewBuilder private func repoMenu(_ repo: AddedRepo) -> some View {
        Button("Add or Remove Boards…", systemImage: "square.grid.2x2") { browseRepo = repo }
        Button(repo.kind.isFolder ? "Remove Folder" : "Remove Repository", systemImage: "trash", role: .destructive) { model.removeAddedRepo(repo) }
    }

    private func isFolded(_ repo: AddedRepo) -> Bool { foldedRepos.split(separator: "\n").contains(Substring(repo.id)) }
    private func toggleFolded(_ repo: AddedRepo) {
        var ids = foldedRepos.split(separator: "\n").map(String.init)
        if let index = ids.firstIndex(of: repo.id) { ids.remove(at: index) } else { ids.append(repo.id) }
        withAnimation(.snappy(duration: 0.25)) { foldedRepos = ids.joined(separator: "\n") }
    }

    /// A row of the card at the top: icon, name, count.
    private func topRow(_ title: String, _ symbol: String, tint: Color, count: Int, subtitle: String? = nil) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if count > 0 { CountBadge(count: count) }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private var addMenu: some View {
        Group {
            if model.isConnected {
                Button("Add Repository…", systemImage: "book.closed") { showAdd = true }
            }
            Button("Add Folder Server…", systemImage: "server.rack") { showAddServer = true }
        }
    }

    private func boardRow(_ repo: AddedRepo, _ board: SelectedBoard) -> some View {
        Button {
            Task { await model.openBoard(repo, folder: board.folder) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: board.icon ?? BoardAppearance.defaultIcon)
                    .font(.title3).foregroundStyle(Color(boardColor: board.color)).frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(board.name).font(.body).foregroundStyle(.primary)
                    Text(boardSubtitle(repo, board)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if changedCount(repo, board) > 0 {
                    CountBadge(count: changedCount(repo, board), color: Color(boardColor: board.color))
                        .accessibilityLabel("\(changedCount(repo, board)) new or moved since you last opened it")
                }
            }
            .padding(.leading, 30).padding(.trailing, 16).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task { await model.loadBoardCount(repo, board.folder) }
        .contextMenu {
            Button("Remove", systemImage: "minus.circle", role: .destructive) { model.removeBoard(board, from: repo) }
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    TasksMark(animated: false).frame(width: 30, height: 30).foregroundStyle(.primary)
                    Text("Tasks").font(.title2.weight(.bold))
                    Spacer()
                    Menu {
                        addMenu
                        Divider()
                        Button("AI Settings…", systemImage: "sparkles") { showAISettings = true }
                        Button("Notifications…", systemImage: "bell") { showNotificationSettings = true }
                        Divider()
                        if let login = model.connection?.login {
                            Text("Signed in as \(login)")
                            Button("Sign Out", role: .destructive) { model.signOut() }
                        } else {
                            Button("Connect a Git Provider…", systemImage: "person.badge.key") { showConnect = true }
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.body.weight(.semibold))
                            .frame(width: 36, height: 36).background(.quaternary, in: Circle())
                    }
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("homeMenu")
                }
                .padding(.horizontal, 4)

                VStack(spacing: 0) {
                    Button { searchAllTasks = false; showAllTasks = true } label: {
                        topRow("All Tasks", "tray.full", tint: .accentColor, count: model.allTasksCount)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("homeAllTasksRow")
                    if model.hasReviews {
                        let waiting = model.pendingReviewTotal
                        Divider().padding(.leading, 58)
                        Button { showReviews = true } label: {
                            topRow("Reviews", waiting > 0 ? "checkmark.seal.fill" : "checkmark.seal", tint: .orange, count: waiting,
                                   subtitle: waiting > 0 ? nil : "Nothing is waiting for you")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("homeReviewsRow")
                    }
                }
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))

                // A board that appeared in a repository you already have: add it, or not.
                ForEach(model.boardSuggestions) { suggestion in
                    VStack(alignment: .leading, spacing: 10) {
                        Label("New board: \(suggestion.name)", systemImage: "sparkles.rectangle.stack").font(.headline)
                        Text("\(suggestion.repoName) has a board that is not on this phone yet. Add it?")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("Add") { model.addSuggestedBoard(suggestion) }.buttonStyle(.borderedProminent)
                            Button("Not Now") { model.dismissBoardSuggestion(suggestion) }.buttonStyle(.bordered)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("boardSuggestion")
                }

                ForEach(model.addedRepos) { repo in
                    VStack(alignment: .leading, spacing: 0) {
                        Button { toggleFolded(repo) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: repo.symbolName).foregroundStyle(.secondary).frame(width: 28)
                                Text(repo.displayName).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                    .rotationEffect(.degrees(isFolded(repo) ? -90 : 0))
                            }
                            .padding(.leading, 16).padding(.trailing, 52).padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(repo.displayName), \(isFolded(repo) ? "folded" : "open")")
                        .contextMenu { repoMenu(repo) }
                        // The same choices in sight: adding a board should not need a long press.
                        .overlay(alignment: .trailing) {
                            Menu { repoMenu(repo) } label: {
                                Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                                    .frame(width: 44, height: 40).contentShape(Rectangle())
                            }
                            .padding(.trailing, 6)
                            .accessibilityLabel("\(repo.displayName) options")
                            .accessibilityIdentifier("repoOptions")
                        }
                        if !isFolded(repo) {
                            if repo.boards.isEmpty {
                                Button { browseRepo = repo } label: {
                                    Label("Browse boards…", systemImage: "square.grid.2x2")
                                        .padding(.leading, 30).padding(.vertical, 10)
                                }
                            }
                            ForEach(repo.boards) { board in boardRow(repo, board) }
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 96)
        }
        .background(Theme.window)
        // Home, add, search: the three things a thumb reaches for.
        .safeAreaInset(edge: .bottom) {
            HStack {
                Image(systemName: "house.fill").font(.title3).frame(width: 56, height: 44)
                    .accessibilityLabel("Home").accessibilityAddTraits(.isSelected)
                Spacer()
                Menu { addMenu } label: {
                    Image(systemName: "plus").font(.title2.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 54, height: 54).background(Color.accentColor, in: Circle())
                }
                .accessibilityLabel("Add")
                .accessibilityIdentifier("homeAdd")
                Spacer()
                Button { searchAllTasks = true; showAllTasks = true } label: {
                    Image(systemName: "magnifyingglass").font(.title3).frame(width: 56, height: 44)
                }
                .accessibilityLabel("Search tasks")
                .accessibilityIdentifier("homeSearch")
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 22).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(.horizontal, 20).padding(.bottom, 4)
        }
    }

    var body: some View {
        Group {
            if model.addedRepos.isEmpty {
                ContentUnavailableView {
                    Label("No Boards", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Add a repository or a folder server, then browse it to pick which boards to show.")
                } actions: {
                    if model.isConnected {
                        Button("Add Repository") { showAdd = true }.buttonStyle(.borderedProminent)
                    }
                    Button("Add Folder Server") { showAddServer = true }
                }
            } else {
                home
            }
        }
        .overlay {
            if model.isLoadingBoard {
                ProgressView("Opening board…").padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .navigationTitle("Boards")
        .toolbar(model.addedRepos.isEmpty ? .visible : .hidden, for: .navigationBar)
        .sheet(isPresented: $showAllTasks) {
            NavigationStack { AllTasksView(startSearching: searchAllTasks) }.environment(model)
        }
        .refreshable {
            await model.refreshBoardSummaries()
            await model.refreshBoardSuggestions()
            await model.loadReviewInbox()
        }
        // Reviews on every board: on launch, whenever the app comes forward, and when a
        // board is added or removed.
        .task(id: "\(scenePhase == .active)\n\(model.reviewInboxKey)") { if scenePhase == .active { await model.loadReviewInbox() } }
        .sheet(isPresented: $showReviews) { NavigationStack { ReviewInboxView() }.environment(model) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if model.isConnected {
                        Button("Add Repository…", systemImage: "book.closed") { showAdd = true }
                    }
                    Button("Add Folder Server…", systemImage: "server.rack") { showAddServer = true }
                } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("AI Settings…", systemImage: "sparkles") { showAISettings = true }
                    Button("Notifications…", systemImage: "bell") { showNotificationSettings = true }
                    if let login = model.connection?.login {
                        Text("Signed in as \(login)")
                        Button("Sign Out", role: .destructive) { model.signOut() }
                    } else {
                        Button("Connect a Git Provider…", systemImage: "person.badge.key") { showConnect = true }
                    }
                } label: { Image(systemName: "person.crop.circle") }
            }
        }
        .sheet(isPresented: $showAISettings) { AISettingsSheet().environment(model) }
        .sheet(isPresented: $showNotificationSettings) { NotificationSettingsSheet().environment(model) }
        // A tapped notification about reviews opens them.
        .onChange(of: model.wantsReviews, initial: true) { _, wants in
            if wants { model.wantsReviews = false; showReviews = true }
        }
        .sheet(isPresented: $showAdd) { NavigationStack { AddRepoView() }.environment(model) }
        .sheet(isPresented: $showAddServer) {
            NavigationStack {
                Form {
                    Section {
                        FolderServerPicker { added in
                            showAddServer = false
                            browseRepo = added
                        }
                    } header: {
                        Text("On this network")
                    } footer: {
                        Text("Once added, a server keeps working away from home over Tailscale.")
                    }
                    if let error = model.errorMessage {
                        Section { Text(error).font(.callout).foregroundStyle(.red) }
                    }
                }
                .navigationTitle("Add Folder Server")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { showAddServer = false } } }
            }
            .environment(model)
        }
        .sheet(isPresented: $showConnect) {
            NavigationStack { ConnectView() }
                .environment(model)
                .onChange(of: model.isConnected) { _, connected in if connected { showConnect = false } }
        }
        .sheet(item: $browseRepo) { repo in NavigationStack { BoardPickerView(repo: repo) }.environment(model) }
    }
}

/// Pick a repository from the account to add. After adding, browse it to select boards.
private struct AddRepoView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var picked: AddedRepo?

    private var available: [GitRepository] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.repos }
        return model.repos.filter { model.fullName($0).lowercased().contains(q) }
    }

    var body: some View {
        Group {
            if model.isLoadingRepos && model.repos.isEmpty {
                ProgressView("Loading repositories…")
            } else {
                List(available, id: \.reference) { repo in
                    Button {
                        picked = model.addRepo(repo)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed").foregroundStyle(.secondary)
                            Text(model.fullName(repo)).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .searchable(text: $query, prompt: "Filter repositories")
                .refreshable { await model.loadRepos() }
            }
        }
        .navigationTitle("Add Repository")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        .task { if model.repos.isEmpty { await model.loadRepos() } }
        .navigationDestination(item: $picked) { repo in
            BoardPickerView(repo: repo, onDone: { dismiss() })
        }
    }
}

/// Browse a repo's folders and check whichever ones you want as boards — no scanning
/// or heuristics; you pick the folders directly, at any depth.
private struct BoardPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let repo: AddedRepo
    var onDone: (() -> Void)? = nil

    /// folder path → display name of the boards you've checked.
    @State private var selected: [String: String] = [:]

    var body: some View {
        FolderLevel(repo: repo, path: "", title: repo.name, selected: $selected) {
            let boards = selected.map { SelectedBoard(folder: $0.key, name: $0.value) }
            model.setBoards(boards, for: repo.id)
            if let onDone { onDone() } else { dismiss() }
        }
        .onAppear {
            if selected.isEmpty {
                selected = Dictionary(uniqueKeysWithValues: repo.boards.map { ($0.folder, $0.name) })
            }
        }
    }
}

/// One level of the repo folder tree. Check a folder to include it as a board; tap it to
/// go deeper. Done saves from any level.
private struct FolderLevel: View {
    @Environment(AppModel.self) private var model
    let repo: AddedRepo
    let path: String
    let title: String
    @Binding var selected: [String: String]
    let commit: () -> Void

    @State private var folders: [BoardFileEntry]?

    private func name(for folderPath: String) -> String {
        folderPath.split(separator: "/").last.map(String.init) ?? repo.name
    }
    private func toggle(_ folderPath: String) {
        if selected[folderPath] != nil { selected[folderPath] = nil }
        else { selected[folderPath] = name(for: folderPath) }
    }

    /// Whether all subfolders are currently selected.
    private var allSubfoldersSelected: Bool {
        guard let folders, !folders.isEmpty else { return false }
        return folders.allSatisfy { selected[$0.path] != nil }
    }

    /// Select or deselect all immediate subfolders.
    private func toggleAllSubfolders() {
        guard let folders else { return }
        if allSubfoldersSelected {
            // Deselect all
            for folder in folders {
                selected[folder.path] = nil
            }
        } else {
            // Select all
            for folder in folders {
                selected[folder.path] = name(for: folder.path)
            }
        }
    }

    var body: some View {
        List {
            Section {
                Button { toggle(path) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selected[path] != nil ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected[path] != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(path.isEmpty ? "Use repository root as a board" : "Use \"\(title)\" as a board")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Section {
                if let folders {
                    if folders.isEmpty {
                        Text("No subfolders").foregroundStyle(.secondary)
                    } else {
                        ForEach(folders, id: \.path) { entry in
                            HStack(spacing: 12) {
                                // Larger tap target for checkbox only
                                Button { toggle(entry.path) } label: {
                                    Image(systemName: selected[entry.path] != nil ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected[entry.path] != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                        .frame(width: 28, height: 28)
                                }
                                .buttonStyle(.plain)
                                NavigationLink {
                                    FolderLevel(repo: repo, path: entry.path, title: entry.name, selected: $selected, commit: commit)
                                        .environment(model)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "folder.fill").foregroundStyle(.tint)
                                        Text(entry.name)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
                }
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    if let folders, !folders.isEmpty {
                        Button(allSubfoldersSelected ? "Deselect All" : "Select All") {
                            toggleAllSubfolders()
                        }
                        .font(.caption)
                        .textCase(nil)
                    }
                }
            }
        }
        .navigationTitle(path.isEmpty ? "Select Boards" : title)
        .navigationBarTitleDisplayMode(.inline)
        .task { folders = await model.listFolders(in: repo, at: path) }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { commit() }
            }
        }
    }
}

/// Address field + connect button for a GitKanban folder server.
struct AddFolderServerRow: View {
    @Environment(AppModel.self) private var model
    var onAdded: (AddedRepo) -> Void = { _ in }
    @State private var address = ""
    @State private var isChecking = false

    var body: some View {
        TextField("my-mac.tailnet.ts.net", text: $address)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .submitLabel(.go)
            .onSubmit(connect)
            .accessibilityIdentifier("folderServerAddress")
        Button(action: connect) {
            HStack {
                Image(systemName: "server.rack")
                Text("Connect to Folder Server")
                Spacer()
                if isChecking { ProgressView() }
            }
        }
        .disabled(isChecking || address.trimmingCharacters(in: .whitespaces).isEmpty)
        .accessibilityIdentifier("connectFolderServer")
    }

    private func connect() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            if let added = await model.addFolderServer(address) { onAdded(added) }
        }
    }
}
