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
                    ProgressView("Loading…")
                } else if model.activeRepo != nil || model.isDemo {
                    BoardScreen()
                } else if !model.isConnected {
                    ConnectView()
                } else {
                    HomeView()
                }
            }
        }
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
                    Image("GitKanbanLines")
                        .resizable().scaledToFit().frame(width: 84, height: 76)
                        .foregroundStyle(.tint)
                    Text("GitKittie Kanban").font(.title.bold())
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
                Text("Copied. Open GitHub, paste this code, and confirm to authorise GitKittie Kanban.")
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
    @State private var browseRepo: AddedRepo?

    /// "N tasks · <folder>" for a board row (task count loads lazily).
    private func boardSubtitle(_ repo: AddedRepo, _ board: SelectedBoard) -> String {
        var parts: [String] = []
        if let n = model.boardCount(repo, board.folder) { parts.append("\(n) task\(n == 1 ? "" : "s")") }
        if !board.folder.isEmpty { parts.append(board.folder) }
        return parts.isEmpty ? "Loading…" : parts.joined(separator: " · ")
    }

    var body: some View {
        Group {
            if model.addedRepos.isEmpty {
                ContentUnavailableView {
                    Label("No Boards", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Add a repository, then browse it to pick which boards to show.")
                } actions: {
                    Button("Add Repository") { showAdd = true }.buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(model.addedRepos) { repo in
                        Section {
                            if repo.boards.isEmpty {
                                Button { browseRepo = repo } label: {
                                    Label("Browse boards…", systemImage: "square.grid.2x2")
                                }
                            } else {
                                ForEach(repo.boards) { board in
                                    Button {
                                        Task { await model.openBoard(repo, folder: board.folder) }
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "square.stack.3d.up.fill")
                                                .font(.title3).foregroundStyle(.tint).frame(width: 26)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(board.name).font(.body).foregroundStyle(.primary)
                                                Text(boardSubtitle(repo, board)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                            Spacer(minLength: 8)
                                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .task { await model.loadBoardCount(repo, board.folder) }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) { model.removeBoard(board, from: repo) } label: {
                                            Label("Remove", systemImage: "minus.circle")
                                        }
                                    }
                                }
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed").font(.caption2)
                                Text(repo.fullName).textCase(nil)
                                Spacer()
                                Menu {
                                    Button("Browse Boards…", systemImage: "square.grid.2x2") { browseRepo = repo }
                                    Button("Remove Repository", systemImage: "trash", role: .destructive) { model.removeAddedRepo(repo) }
                                } label: { Image(systemName: "ellipsis.circle") }
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if model.isLoadingBoard {
                ProgressView("Opening board…").padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .navigationTitle("Boards")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    if let login = model.connection?.login { Text("Signed in as \(login)") }
                    Button("Sign Out", role: .destructive) { model.signOut() }
                } label: { Image(systemName: "person.crop.circle") }
            }
        }
        .sheet(isPresented: $showAdd) { NavigationStack { AddRepoView() }.environment(model) }
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

    var body: some View {
        List {
            Section {
                Button { toggle(path) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selected[path] != nil ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected[path] != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(path.isEmpty ? "Use repository root as a board" : "Use “\(title)” as a board")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Section("Folders") {
                if let folders {
                    if folders.isEmpty {
                        Text("No subfolders").foregroundStyle(.secondary)
                    }
                    ForEach(folders, id: \.path) { entry in
                        HStack(spacing: 12) {
                            Button { toggle(entry.path) } label: {
                                Image(systemName: selected[entry.path] != nil ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected[entry.path] != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
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
                } else {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
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
