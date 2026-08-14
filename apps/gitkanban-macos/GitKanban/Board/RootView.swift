import GitKittieKit
import GitKanbanKit
import GitPontCore
import SwiftUI

/// Top-level flow: restore → connect → a split view with the boards sidebar + board.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isRestoring {
            SplashView()
        } else if model.isDemo {
            NavigationStack { BoardScreen() }
        } else if !model.isConnected {
            ConnectView()
        } else {
            WorkspaceSplit()
        }
    }
}

/// Clean splash screen shown while restoring session.
private struct SplashView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image("GitKanbanLines")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .foregroundStyle(.primary.opacity(0.7))

            Text("GitKittie Kanban")
                .font(.title2.weight(.medium))
                .foregroundStyle(.primary.opacity(0.8))

            ProgressView()
                .controlSize(.small)
                .padding(.top, 8)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The connected working screen: a sidebar of added repos + their boards, and the
/// selected board in the detail pane.
private struct WorkspaceSplit: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false
    @State private var browseRepo: AddedRepo?

    /// Sidebar selection is a "repoID|folder" key mirroring the open board.
    private var selection: Binding<String?> {
        Binding(
            get: { model.activeRepo.map { "\($0.id)|\(model.activeBoardFolder ?? "")" } },
            set: { key in
                guard let key, let sep = key.range(of: "|") else { return }
                let repoID = String(key[..<sep.lowerBound])
                let folder = String(key[sep.upperBound...])
                if let repo = model.addedRepos.first(where: { $0.id == repoID }) {
                    Task { await model.openBoard(repo, folder: folder) }
                }
            }
        )
    }

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: selection) {
                ForEach(model.addedRepos) { repo in
                    Section {
                        if repo.boards.isEmpty {
                            Button { browseRepo = repo } label: {
                                Text("Browse boards…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        } else {
                            ForEach(repo.boards) { board in
                                HStack(spacing: 10) {
                                    Image(systemName: "square.stack.3d.up.fill")
                                        .font(.caption)
                                        .foregroundStyle(.tint)
                                    Text(board.name)
                                        .font(.callout)
                                }
                                .tag("\(repo.id)|\(board.folder)")
                            }
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(repo.name)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Menu {
                                Button("Browse Boards…", systemImage: "square.grid.2x2") { browseRepo = repo }
                                Divider()
                                Button("Remove Repository", systemImage: "trash", role: .destructive) { model.removeAddedRepo(repo) }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .overlay {
                if model.addedRepos.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("No Boards")
                            .font(.headline)
                        Text("Add a repository to get started.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Add Repository") { showAdd = true }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .navigation) {
                    Menu {
                        if let login = model.connection?.login {
                            Text("Signed in as \(login)")
                        }
                        Divider()
                        Button("Sign Out", role: .destructive) { model.signOut() }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
        } detail: {
            if model.activeRepo != nil {
                BoardScreen()
            } else {
                VStack(spacing: 14) {
                    Image("GitKanbanLines")
                        .resizable().scaledToFit().frame(width: 104)
                        .foregroundStyle(.tertiary)
                    Text("Select a board").font(.title2.bold())
                    Text("Choose a board from the sidebar, or add a repository.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showAdd) { NavigationStack { AddRepoView() }.environment(model).frame(minWidth: 460, minHeight: 480) }
        .sheet(item: $browseRepo) { repo in NavigationStack { BoardPickerView(repo: repo) }.environment(model).frame(minWidth: 460, minHeight: 480) }
    }
}

/// Clean splash/connect screen with minimal, luxurious design.
private struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    @State private var choice: ProviderChoice = .github
    @State private var serverURL = ""
    @State private var token = ""
    @State private var showTokenField = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Logo and title
            VStack(spacing: 16) {
                Image("GitKanbanLines")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .foregroundStyle(.primary.opacity(0.8))

                VStack(spacing: 6) {
                    Text("GitKittie Kanban")
                        .font(.largeTitle.weight(.semibold))
                    Text("Your kanban board is a git repo.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Actions
            if let device = model.deviceAuth {
                deviceCodeView(device)
            } else {
                VStack(spacing: 16) {
                    // Demo button - primary action for no-account users
                    Button {
                        Task { await model.loadDemo() }
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                            Text("Try the Demo")
                        }
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    // Sign in with GitHub
                    Button {
                        Task { await model.startGitHubOAuth() }
                    } label: {
                        HStack {
                            Image(systemName: "person.badge.key.fill")
                            Text("Sign in with GitHub")
                            if model.isConnecting && model.deviceAuth == nil {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isConnecting)

                    // Token / other providers - collapsed by default
                    if showTokenField {
                        VStack(spacing: 12) {
                            Picker("Provider", selection: $choice) {
                                ForEach(ProviderChoice.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)

                            if choice.needsServerURL {
                                TextField("Server URL (e.g. git.acme.com)", text: $serverURL)
                                    .textFieldStyle(.roundedBorder)
                            }

                            SecureField("Personal access token", text: $token)
                                .textFieldStyle(.roundedBorder)

                            Button {
                                Task { await model.connect(choice: choice, serverURL: serverURL, token: token) }
                            } label: {
                                HStack {
                                    Text("Connect")
                                    if model.isConnecting { ProgressView().controlSize(.small) }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isConnecting || token.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding(.top, 8)
                    } else {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showTokenField = true }
                        } label: {
                            Text("Use a token instead")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 320)
            }

            Spacer()

            // Error message
            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding()
            }

            // Footer
            Text("No data leaves your device without your permission.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func deviceCodeView(_ device: GitOAuthDeviceSession) -> some View {
        VStack(spacing: 20) {
            Text("Enter this code on GitHub")
                .font(.headline)

            Text(device.userCode)
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .tracking(4)
                .textSelection(.enabled)
                .padding(.vertical, 16)
                .padding(.horizontal, 32)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 16) {
                Button { Platform.copy(device.userCode) } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Button { openURL(device.verificationURI) } label: {
                    Label("Open GitHub", systemImage: "arrow.up.right")
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for authorization…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            Button("Cancel") { model.cancelOAuth() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 360)
        .onAppear { openURL(device.verificationURI) }
    }
}

/// Home: added repos, each showing the boards you picked. Add a repo, browse it, open a board.
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
            }
        }
        .navigationTitle("Add Repository")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .task { if model.repos.isEmpty { await model.loadRepos() } }
        .navigationDestination(item: $picked) { repo in
            BoardPickerView(repo: repo, onDone: { dismiss() })
        }
    }
}

/// Browse a repo's folders and check whichever ones you want as boards.
private struct BoardPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let repo: AddedRepo
    var onDone: (() -> Void)? = nil

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

/// One level of the repo folder tree. Check a folder to include it as a board; open it to go deeper.
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
                                        .frame(width: 24, height: 24)
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
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }
                }
            }
        }
        .navigationTitle(path.isEmpty ? "Select Boards" : title)
        .task { folders = await model.listFolders(in: repo, at: path) }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { commit() } }
        }
    }
}
