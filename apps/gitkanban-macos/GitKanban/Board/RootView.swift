import GitKittieKit
import GitKanbanKit
import GitPontCore
import AppKit
import SwiftUI

/// Top-level flow: restore → connect → a split view with the boards sidebar + board.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isRestoring {
            SplashView()
        } else if model.isDemo {
            NavigationStack { BoardScreen() }
        } else if !model.hasHome {
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
            // The same animated mark and wordmark as the iOS app (TasksMark.swift).
            TasksWordmark()

            ProgressView()
                .controlSize(.small)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // No title bar while loading: the screen runs to the top of the window, so the
        // mark sits in the middle of the whole window.
        .ignoresSafeArea()
        .background(TitleBarHider())
    }
}

/// Hides the window's title bar (title text and its background strip) for as long as the
/// view is on screen, and puts back what was there when it leaves.
private struct TitleBarHider: NSViewRepresentable {
    final class Probe: NSView {
        private var saved: (title: NSWindow.TitleVisibility, transparent: Bool, fullSize: Bool)?
        private weak var hiddenWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            restore()
            guard let window else { return }
            saved = (window.titleVisibility, window.titlebarAppearsTransparent, window.styleMask.contains(.fullSizeContentView))
            hiddenWindow = window
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
        }

        func restore() {
            guard let window = hiddenWindow, let saved else { return }
            window.titleVisibility = saved.title
            window.titlebarAppearsTransparent = saved.transparent
            if !saved.fullSize { window.styleMask.remove(.fullSizeContentView) }
            hiddenWindow = nil
            self.saved = nil
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.restore() }
}


/// The connected working screen: a sidebar of added repos + their boards, and the
/// selected board in the detail pane.
private struct WorkspaceSplit: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false
    @State private var showAddServer = false
    @State private var showConnect = false
    @State private var serverAddress = ""
    @State private var isCheckingServer = false
    @State private var browseRepo: AddedRepo?
    @State private var appearanceTarget: AppearanceTarget?
    @State private var showAgentAccess = false
    @Environment(\.scenePhase) private var scenePhase

    private struct AppearanceTarget: Identifiable {
        let repo: AddedRepo
        let board: SelectedBoard
        var id: String { "\(repo.id)|\(board.folder)" }
    }

    private func openFolder() {
        guard let url = pickFolder() else { return }
        do { browseRepo = try model.addLocalFolder(url) } catch { model.errorMessage = error.localizedDescription }
    }

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
                                    Image(systemName: board.icon ?? BoardAppearance.defaultIcon)
                                        .font(.caption)
                                        .foregroundStyle(Color(boardColor: board.color))
                                        .frame(width: 16)
                                    Text(board.name)
                                        .font(.callout)
                                    Spacer(minLength: 4)
                                    if model.isLoadingBoard, model.activeRepo?.id == repo.id, model.activeBoardFolder == board.folder {
                                        ProgressView().controlSize(.small)
                                    } else if let changed = model.boardSummary(repo, board.folder)?.changed, changed > 0 {
                                        // Cards that are new or moved lane since this board was last opened.
                                        Text("\(changed)")
                                            .font(.caption2.weight(.semibold).monospacedDigit())
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(Color(boardColor: board.color), in: Capsule())
                                            .accessibilityLabel("\(changed) updated")
                                    }
                                }
                                .tag("\(repo.id)|\(board.folder)")
                                .contextMenu {
                                    Button("Open", systemImage: "square.stack.3d.up") {
                                        Task { await model.openBoard(repo, folder: board.folder) }
                                    }
                                    Button("Reload", systemImage: "arrow.clockwise") {
                                        Task { await model.openBoard(repo, folder: board.folder) }
                                    }
                                    Button("Board Settings…", systemImage: "gearshape") {
                                        appearanceTarget = AppearanceTarget(repo: repo, board: board)
                                    }
                                    Divider()
                                    Button("Browse Boards…", systemImage: "square.grid.2x2") { browseRepo = repo }
                                    Divider()
                                    Button("Remove from Sidebar", systemImage: "minus.circle", role: .destructive) {
                                        if model.activeRepo?.id == repo.id, model.activeBoardFolder == board.folder { model.closeRepo() }
                                        model.removeBoard(board, from: repo)
                                    }
                                }
                            }
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Image(systemName: repo.symbolName)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(repo.displayName)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Menu {
                                Button("Browse Boards…", systemImage: "square.grid.2x2") { browseRepo = repo }
                                Divider()
                                Button(repo.kind.isFolder ? "Remove Folder" : "Remove Repository", systemImage: "trash", role: .destructive) { model.removeAddedRepo(repo) }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                        .contextMenu {
                            Button("Browse Boards…", systemImage: "square.grid.2x2") { browseRepo = repo }
                            Divider()
                            Button(repo.kind.isFolder ? "Remove Folder" : "Remove Repository", systemImage: "trash", role: .destructive) { model.removeAddedRepo(repo) }
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
                        Text("Add a repository or open a folder to get started.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if model.isConnected {
                            Button("Add Repository") { showAdd = true }
                                .buttonStyle(.bordered)
                        }
                        Button("Open a Folder…") { openFolder() }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if model.isConnected {
                            Button("Add Repository…", systemImage: "book.closed") { showAdd = true }
                        }
                        Button("Open a Folder…", systemImage: "folder") { openFolder() }
                        Button("Add Folder Server…", systemImage: "server.rack") { showAddServer = true }
                        if !model.addedRepos.isEmpty {
                            Divider()
                            // More boards from something that is already in the sidebar.
                            if model.addedRepos.count == 1, let only = model.addedRepos.first {
                                Button("Add Board from \(only.displayName)…", systemImage: "square.stack.3d.up") { browseRepo = only }
                            } else {
                                Menu("Add Board from", systemImage: "square.stack.3d.up") {
                                    ForEach(model.addedRepos) { repo in
                                        Button(repo.displayName, systemImage: repo.symbolName) { browseRepo = repo }
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .navigation) {
                    Menu {
                        Button("Agent Access…", systemImage: "point.3.connected.trianglepath.dotted") { showAgentAccess = true }
                        Divider()
                        if let login = model.connection?.login {
                            Text("Signed in as \(login)")
                            Divider()
                            Button("Sign Out", role: .destructive) { model.signOut() }
                        } else {
                            Button("Connect a Git Provider…") { showConnect = true }
                        }
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
        .sheet(isPresented: $showAgentAccess) { AgentAccessSheet().environment(model) }
        .sheet(item: $appearanceTarget) { target in
            BoardSettingsSheet(repo: target.repo, board: target.board).environment(model)
        }
        // What changed on each board since it was last opened (the sidebar badges), and
        // each board's icon and colour: on launch, and again whenever the app comes forward.
        .task(id: scenePhase) {
            if scenePhase == .active { await model.refreshBoardSummaries() }
        }
        .sheet(isPresented: $showAdd) { NavigationStack { AddRepoView() }.environment(model).frame(minWidth: 460, minHeight: 480) }
        .sheet(item: $browseRepo) { repo in NavigationStack { BoardPickerView(repo: repo) }.environment(model).frame(minWidth: 460, minHeight: 480) }
        .sheet(isPresented: $showConnect) {
            ConnectView()
                .environment(model)
                .frame(minWidth: 460, minHeight: 560)
                .onChange(of: model.isConnected) { _, connected in if connected { showConnect = false } }
        }
        .sheet(isPresented: $showAddServer) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add Folder Server").font(.headline)
                DiscoveredServerList { added in
                    showAddServer = false
                    browseRepo = added
                }
                Text("Or enter an address, e.g. a Mac's Tailscale name.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("my-mac.tailnet.ts.net", text: $serverAddress)
                    .textFieldStyle(.roundedBorder)
                if let error = model.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { showAddServer = false }
                    Button("Connect") {
                        isCheckingServer = true
                        Task {
                            defer { isCheckingServer = false }
                            if let added = await model.addFolderServer(serverAddress) {
                                showAddServer = false
                                browseRepo = added
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCheckingServer || serverAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 420)
        }
    }
}

/// Folder servers announced on the local network, each one click away.
struct DiscoveredServerList: View {
    @Environment(AppModel.self) private var model
    var onAdded: (AddedRepo) -> Void
    @State private var browser = FolderServerBrowser()
    @State private var connecting: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if browser.servers.isEmpty {
                HStack(spacing: 8) {
                    if browser.problem == nil { ProgressView().controlSize(.small) }
                    Text(browser.problem ?? "Looking for servers on this network…")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(browser.servers) { server in
                Button { connect(server) } label: {
                    HStack {
                        Image(systemName: "server.rack")
                        VStack(alignment: .leading) {
                            Text(server.name)
                            Text(server.url.flatMap { URL(string: $0)?.host } ?? "No address yet. Turn on Tailscale on that Mac.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if connecting == server.id {
                            ProgressView().controlSize(.small)
                        } else if model.addedServer(for: server) != nil {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(connecting != nil || server.url == nil)
            }
        }
        .padding(.vertical, 4)
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private func connect(_ server: DiscoveredServer) {
        connecting = server.id
        Task {
            defer { connecting = nil }
            if let added = await model.addDiscoveredServer(server) { onAdded(added) }
        }
    }
}

/// A folder picker for opening a plain folder as a board source.
@MainActor
func pickFolder() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Open"
    panel.message = "Choose a folder of boards. GitKanban reads and writes its files and does no git."
    return panel.runModal() == .OK ? panel.url : nil
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
                    Text("Tasks")
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

                    // A plain folder — no git; the folder's own sync tool (e.g. GitFolder) commits.
                    Button {
                        if let url = pickFolder() { try? model.addLocalFolder(url) }
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                            Text("Open a Folder…")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
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

/// Choose a repo's boards. A repo that already has boards opens on the folders next to
/// them (the other projects of the same workspace), each one a checkbox away; the whole
/// folder tree is still there to browse for anything else.
private struct BoardPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let repo: AddedRepo
    var onDone: (() -> Void)? = nil

    @State private var selected: [String: String] = [:]
    /// The folders next to the boards the repo already has, per parent folder.
    @State private var siblings: [(parent: String, folders: [BoardFileEntry])]?
    @State private var filter = ""

    /// The folders the current boards live in ("Tasks" for "Tasks/Arvik").
    private var parents: [String] {
        Set(repo.boards.compactMap { board -> String? in
            guard let slash = board.folder.lastIndex(of: "/") else { return board.folder.isEmpty ? nil : "" }
            return String(board.folder[..<slash])
        }).sorted()
    }

    private func commit() {
        let boards = selected.map { SelectedBoard(folder: $0.key, name: $0.value) }
        model.setBoards(boards, for: repo.id)
        if let onDone { onDone() } else { dismiss() }
    }

    private func matches(_ entry: BoardFileEntry) -> Bool {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || entry.name.localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        Group {
            if parents.isEmpty {
                FolderLevel(repo: repo, path: "", title: repo.name, selected: $selected, commit: commit)
            } else {
                quickPicker
            }
        }
        .onAppear {
            if selected.isEmpty {
                selected = Dictionary(uniqueKeysWithValues: repo.boards.map { ($0.folder, $0.name) })
            }
        }
    }

    private var quickPicker: some View {
        List {
            if let siblings {
                ForEach(siblings, id: \.parent) { group in
                    let shown = group.folders.filter(matches)
                    let missing = shown.filter { selected[$0.path] == nil }
                    Section {
                        if shown.isEmpty {
                            Text(group.folders.isEmpty ? "No folders" : "No folder matches \"\(filter)\"").foregroundStyle(.secondary)
                        }
                        // What is not a board yet comes first: that is what you came to add.
                        ForEach(missing + shown.filter { selected[$0.path] != nil }, id: \.path) { entry in
                            Toggle(isOn: Binding(
                                get: { selected[entry.path] != nil },
                                set: { selected[entry.path] = $0 ? entry.name : nil }
                            )) {
                                HStack(spacing: 8) {
                                    Image(systemName: "square.stack.3d.up.fill").font(.caption).foregroundStyle(.tint)
                                    Text(entry.name)
                                    if !repo.boards.contains(where: { $0.folder == entry.path }) {
                                        Text("not added").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    } header: {
                        HStack {
                            Text(group.parent.isEmpty ? repo.name : group.parent)
                            Spacer()
                            if !missing.isEmpty {
                                Button("Add All \(missing.count)") {
                                    for entry in missing { selected[entry.path] = entry.name }
                                }
                                .font(.caption).buttonStyle(.plain).foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for boards…").foregroundStyle(.secondary) }
            }
            Section {
                NavigationLink {
                    FolderLevel(repo: repo, path: "", title: repo.name, selected: $selected, commit: commit)
                        .environment(model)
                } label: {
                    Label("Browse All Folders…", systemImage: "folder")
                }
            }
        }
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter boards")
        .navigationTitle("Boards in \(repo.displayName)")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if let onDone { onDone() } else { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) { Button("Done") { commit() } }
        }
        .task {
            var found: [(parent: String, folders: [BoardFileEntry])] = []
            for parent in parents {
                // "attachments" sits next to the lanes of a board, it is never a board itself.
                let folders = await model.listFolders(in: repo, at: parent).filter { $0.name != "attachments" }
                found.append((parent, folders))
            }
            siblings = found
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
