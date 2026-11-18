import AppKit
import GitKittieKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedSection: SettingsSection = .sync
    @State private var isSidebarExpanded = true
    @State private var githubToken = ""
    @State private var gitHubAuthMode: GitHubAuthSetupMode = .connect
    @State private var gitHubAuthorization: GitHubDeviceAuthorization?
    @State private var isConnectingGitHub = false
    @State private var gitHubConnectionMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
                .frame(width: isSidebarExpanded ? 232 : 76)
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)

            VStack(spacing: 0) {
                HStack {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            isSidebarExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isSidebarExpanded ? "sidebar.left" : "sidebar.right")
                    }
                    .buttonStyle(.borderless)
                    .help(isSidebarExpanded ? "Collapse sidebar" : "Expand sidebar")

                    Spacer()
                    Text(selectedSection.title)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.72))
                    Spacer()
                    Color.clear.frame(width: 24, height: 24)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 8)

                settingsPane
            }
            .background(Color.black.opacity(0.92))
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .frame(
            minWidth: 860,
            minHeight: SettingsWindowMetrics.preferredContentHeight,
            maxHeight: SettingsWindowMetrics.maximumContentHeight
        )
        .onAppear {
            appModel.loadIfNeeded()
            if appModel.focusedFolderID != nil {
                selectedSection = .folders
            }
        }
        .onChange(of: appModel.focusedFolderID) { _, focusedFolderID in
            if focusedFolderID != nil {
                selectedSection = .folders
            }
        }
        .sheet(isPresented: Binding(
            get: { appModel.isShowingAddFolderSheet },
            set: { appModel.isShowingAddFolderSheet = $0 }
        )) {
            AddFolderSheet(isPresented: Binding(
                get: { appModel.isShowingAddFolderSheet },
                set: { appModel.isShowingAddFolderSheet = $0 }
            ))
                .environment(appModel)
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 10) {
                AppLogoView(size: 44)
                if isSidebarExpanded {
                    Text("GitFolder")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 44)

            VStack(spacing: 6) {
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: section.systemImage)
                                .font(.title3)
                                .frame(width: 22)
                            if isSidebarExpanded {
                                Text(section.title)
                                    .font(.headline)
                                Spacer()
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .foregroundStyle(selectedSection == section ? Color.white : Color.white.opacity(0.72))
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selectedSection == section ? Color.accentColor.opacity(0.72) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(section.title)
                }
            }

            Spacer()

            if isSidebarExpanded {
                Text(appVersionLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 18)
                    .padding(.leading, 12)
            }
        }
        .padding(.horizontal, isSidebarExpanded ? 16 : 10)
        .background {
            ZStack {
                MacSidebarMaterial()
                Color.black.opacity(0.48)
            }
        }
    }

    @ViewBuilder
    private var settingsPane: some View {
        switch selectedSection {
        case .sync:
            syncSettings
        case .github:
            githubSettings
        case .identity:
            identitySettings
        case .storage:
            storageSettings
        case .folders:
            folderSettings
        }
    }

    private var syncSettings: some View {
        SettingsPane(title: "Sync", subtitle: "Control automatic syncing and run manual updates.") {
            SettingsCard {
                SettingsFieldRow(systemImage: "pause.fill", title: "Pause all syncing") {
                    Toggle(
                        "Pause all syncing",
                        isOn: Binding(
                            get: { appModel.config.app.pauseAllSyncing },
                            set: { newValue in
                                appModel.config.app.pauseAllSyncing = newValue
                                appModel.save(message: newValue ? "Syncing paused" : "Syncing resumed")
                            }
                        )
                    )
                    .labelsHidden()
                }

                SettingsDivider()

                SettingsFieldRow(systemImage: "power", title: "Open at login") {
                    Toggle(
                        "Open at login",
                        isOn: Binding(
                            get: { appModel.config.app.launchAtLogin },
                            set: { newValue in
                                appModel.setLaunchAtLogin(newValue)
                            }
                        )
                    )
                    .labelsHidden()
                }

                SettingsDivider()

                SettingsFieldRow(systemImage: "clock", title: "Default interval") {
                    Picker(
                        "Default interval",
                        selection: Binding(
                            get: { appModel.config.app.defaultSyncIntervalMinutes },
                            set: { newValue in
                                appModel.config.app.defaultSyncIntervalMinutes = newValue
                                appModel.save(message: "Default interval updated")
                            }
                        )
                    ) {
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("60 minutes").tag(60)
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }

                SettingsDivider()

                SettingsFieldRow(systemImage: "arrow.triangle.2.circlepath", title: "Manual sync") {
                    Button(appModel.isSyncing ? "Syncing..." : "Sync All Now", systemImage: "arrow.triangle.2.circlepath") {
                        appModel.syncNow()
                    }
                    .disabled(appModel.isSyncing || appModel.config.folders.isEmpty)
                }
            }
        }
    }

    private var githubSettings: some View {
        SettingsPane(title: "GitHub", subtitle: "Connect GitFolder to GitHub and manage HTTPS token access.") {
            SettingsCard {
                SettingsFieldRow(systemImage: appModel.hasGitHubToken ? "key.fill" : "key", title: "Connection") {
                    HStack(spacing: 12) {
                        Text(gitHubConnectionStatus)
                            .foregroundStyle(appModel.hasGitHubToken ? Color.secondary : Color.orange)
                        if appModel.hasGitHubToken {
                            Button("Disconnect", role: .destructive) {
                                githubToken = ""
                                appModel.clearGitHubToken()
                                gitHubAuthorization = nil
                                gitHubConnectionMessage = nil
                            }
                        }
                    }
                }

                if appModel.hasGitHubToken {
                    SettingsDivider()

                    SettingsFieldRow(systemImage: "person.crop.circle.badge.checkmark", title: "GitHub account") {
                        HStack(spacing: 12) {
                            Text(appModel.gitHubLogin.map { "@\($0)" } ?? "Connected")
                                .foregroundStyle(.secondary)

                            Button(isConnectingGitHub ? "Waiting..." : "Reconnect", systemImage: "arrow.triangle.2.circlepath") {
                                connectGitHub()
                            }
                            .disabled(isConnectingGitHub)
                        }
                    }
                } else {
                    SettingsDivider()

                    SettingsFieldRow(systemImage: "switch.2", title: "Connection method") {
                        Picker("Connection method", selection: $gitHubAuthMode) {
                            Text("Connect").tag(GitHubAuthSetupMode.connect)
                            Text("PAT").tag(GitHubAuthSetupMode.pat)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                    }

                    SettingsDivider()

                    switch gitHubAuthMode {
                    case .connect:
                        SettingsFieldRow(systemImage: "person.crop.circle.badge.checkmark", title: "GitHub account") {
                            VStack(alignment: .trailing, spacing: 10) {
                                Button(isConnectingGitHub ? "Waiting for GitHub..." : "Connect GitHub", systemImage: "link") {
                                    connectGitHub()
                                }
                                .disabled(isConnectingGitHub)

                                if let gitHubAuthorization {
                                    GitHubDeviceCodeRow(authorization: gitHubAuthorization)
                                        .frame(maxWidth: 420)
                                }
                            }
                        }
                    case .pat:
                        SettingsFieldRow(systemImage: "lock.rectangle", title: "Fine-grained token") {
                            HStack(spacing: 10) {
                                SecureField("GitHub token", text: $githubToken)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 320)

                                Button("Save Token") {
                                    appModel.saveGitHubToken(githubToken)
                                    githubToken = ""
                                }
                                .disabled(githubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                }

                if let gitHubAuthorization, appModel.hasGitHubToken {
                    SettingsDivider()
                    GitHubDeviceCodeRow(authorization: gitHubAuthorization)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                }

                if let gitHubConnectionMessage {
                    SettingsDivider()
                    Text(gitHubConnectionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 2)
                }
            }

            Text("GitFolder stores GitHub access in macOS Keychain and uses HTTPS repository URLs by default.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
        }
    }

    private var gitHubConnectionStatus: String {
        guard appModel.hasGitHubToken else { return "No token saved" }
        if let login = appModel.gitHubLogin {
            return "Connected as @\(login)"
        }
        return "Connected with saved token"
    }

    private var identitySettings: some View {
        SettingsPane(title: "Git Identity", subtitle: "Set the Git author used for snapshot commits.") {
            SettingsCard {
                SettingsFieldRow(systemImage: "person", title: "Author name") {
                    TextField(
                        "Name",
                        text: Binding(
                            get: { appModel.config.app.gitAuthorName ?? "" },
                            set: { newValue in
                                appModel.config.app.gitAuthorName = newValue.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                                appModel.save(message: "Git author updated")
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                }

                SettingsDivider()

                SettingsFieldRow(systemImage: "envelope", title: "Author email") {
                    TextField(
                        "Email",
                        text: Binding(
                            get: { appModel.config.app.gitAuthorEmail ?? "" },
                            set: { newValue in
                                appModel.config.app.gitAuthorEmail = newValue.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                                appModel.save(message: "Git email updated")
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                }

            }
        }
    }

    private var storageSettings: some View {
        SettingsPane(title: "Storage", subtitle: "Keep project files visible in Finder while large assets live in your own S3 or R2 bucket.") {
            if appModel.config.folders.isEmpty {
                SettingsCard {
                    ContentUnavailableView(
                        "Add a folder first",
                        systemImage: "externaldrive.badge.plus",
                        description: Text("Bucket settings belong to a synced repository and are written to its .gitfolder.yml file.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                }
            } else {
                ForEach(appModel.config.folders) { folder in
                    BucketSettingsRow(folder: folder)
                }
            }
        }
    }

    private var appVersionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "v\(version) (\(build))"
    }

    private var folderSettings: some View {
        SettingsPane(title: "Folders", subtitle: "Manage the local folders you sync with GitHub.") {
            if appModel.config.folders.isEmpty {
                SettingsCard {
                    ContentUnavailableView(
                        "No folders yet",
                        systemImage: "folder.badge.plus",
                        description: Text("Add a folder and connect it to a GitHub HTTPS repository URL.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                }
            } else {
                ForEach(appModel.config.folders) { folder in
                    FolderSettingsRow(folder: folder)
                }
            }

            Button {
                appModel.showAddFolderSheet()
            } label: {
                Label("Add Folder...", systemImage: "plus")
                    .frame(minWidth: 150)
            }
            .controlSize(.large)
        }
    }

    private func connectGitHub() {
        isConnectingGitHub = true
        gitHubAuthorization = nil
        gitHubConnectionMessage = "Requesting a GitHub sign-in code…"

        Task {
            do {
                let authorization = try await appModel.requestGitHubConnectionCode()
                await MainActor.run {
                    gitHubAuthorization = authorization
                    gitHubConnectionMessage = "Enter this code on GitHub, then approve GitFolder."
                    NSWorkspace.shared.open(authorization.verificationURI)
                }
                let connected = await appModel.finishGitHubConnection(authorization)
                await MainActor.run {
                    isConnectingGitHub = false
                    if connected {
                        gitHubAuthorization = nil
                        gitHubConnectionMessage = "GitHub connected."
                    } else {
                        gitHubConnectionMessage = appModel.lastMessage
                    }
                }
            } catch {
                await MainActor.run {
                    isConnectingGitHub = false
                    appModel.lastMessage = "GitHub connection failed: \(error.localizedDescription)"
                    gitHubConnectionMessage = appModel.lastMessage
                }
            }
        }
    }
}

private struct FolderSettingsRow: View {
    @Environment(AppModel.self) private var appModel
    @State private var draft: SyncedFolder
    @State private var remoteBranches: [String] = []
    @State private var isLoadingBranches = false

    init(folder: SyncedFolder) {
        _draft = State(initialValue: folder)
    }

    var body: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.secondary.opacity(0.14))
                        .frame(width: 62, height: 62)

                    Image(systemName: "folder")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(statusColor(for: currentFolder.lastStatus))
                        .background(Circle().fill(.background))
                        .offset(x: 6, y: 6)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(draft.name)
                            .font(.title3.weight(.semibold))

                        if !draft.enabled {
                            Text("Paused")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.secondary.opacity(0.14))
                                .clipShape(Capsule())
                        }
                    }

                    Text(draft.localPath)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()
                statusBadge
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 16)

            VStack(spacing: 0) {
                FolderFieldRow(systemImage: "link", title: "Repository URL") {
                    HStack(spacing: 10) {
                        TextField("https://github.com/owner/repo.git", text: $draft.repoUrl)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 420)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(draft.repoUrl, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy repository URL")
                        .disabled(draft.repoUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                SettingsDivider()

                FolderFieldRow(systemImage: "point.3.connected.trianglepath.dotted", title: "Branch") {
                    HStack(spacing: 10) {
                        Picker("Branch", selection: $draft.branch) {
                            ForEach(branchPickerOptions, id: \.self) { branch in
                                Text(branch).tag(branch)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)

                        Button {
                            loadBranches()
                        } label: {
                            Image(systemName: isLoadingBranches ? "hourglass" : "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Load branches from GitHub")
                        .disabled(isLoadingBranches || draft.repoUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (appModel.authMode(forRepositoryURL: draft.repoUrl) == .githubToken && !appModel.hasGitHubToken))
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                SettingsDivider()

                FolderFieldRow(systemImage: "clock", title: "Sync Interval") {
                    Picker("Interval", selection: $draft.syncIntervalMinutes) {
                        Text("5 min").tag(5)
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                        Text("60 min").tag(60)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            )
            .padding(.horizontal, 18)

            if let error = latestError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                    if let recoverySuggestion = error.recoverySuggestion {
                        Text(recoverySuggestion)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let paths = error.affectedPaths, !paths.isEmpty {
                        ForEach(paths.prefix(5), id: \.self) { path in
                            Text(path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Button("Exclude from Git and Sync", systemImage: "eye.slash") {
                            appModel.excludeAndSync(paths: paths, folderID: draft.id)
                        }
                        .disabled(appModel.isSyncing)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
            }

            HStack {
                Button(draft.enabled ? "Pause" : "Resume", systemImage: draft.enabled ? "pause.fill" : "play.fill") {
                    appModel.updateFolder(authenticatedDraft())
                    appModel.toggleFolder(id: draft.id)
                    if let updated = appModel.config.folders.first(where: { $0.id == draft.id }) {
                        draft = updated
                    }
                }
                .frame(minWidth: 120)

                Button("Save", systemImage: "square.and.arrow.down") {
                    appModel.updateFolder(authenticatedDraft())
                }
                .frame(minWidth: 120)

                Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                    appModel.updateFolder(authenticatedDraft())
                    appModel.syncNow(folderID: draft.id)
                }
                .buttonStyle(.borderedProminent)
                .frame(minWidth: 140)
                .disabled(appModel.isSyncing || draft.repoUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Repair & Sync", systemImage: "wrench.and.screwdriver") {
                    appModel.updateFolder(authenticatedDraft())
                    appModel.repairAndSync(folderID: draft.id)
                }
                .help("Abort an interrupted Git operation, restore the configured branch, then sync")
                .disabled(appModel.isSyncing || draft.repoUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                Button("Remove", systemImage: "trash", role: .destructive) {
                    appModel.removeFolder(id: draft.id)
                }
                .frame(minWidth: 120)
            }
            .padding(18)
            .padding(.top, 2)
        }
        .overlay(alignment: .top) {
            if isFocused {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
            }
        }
        .contextMenu {
            Button("Sync Now") {
                appModel.updateFolder(authenticatedDraft())
                appModel.syncNow(folderID: draft.id)
            }
            Button("Open Folder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: draft.localPath))
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: draft.localPath)])
            }
            Button(draft.enabled ? "Pause Folder" : "Resume Folder") {
                appModel.toggleFolder(id: draft.id)
            }
        }
        .onChange(of: appModel.config.folders) { _, folders in
            if let updated = folders.first(where: { $0.id == draft.id }), updated.updatedAt != draft.updatedAt {
                draft = updated
            }
        }
        .onChange(of: draft.repoUrl) { _, _ in
            remoteBranches = []
        }
        .onAppear {
            if remoteBranches.isEmpty,
               !draft.repoUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               appModel.authMode(forRepositoryURL: draft.repoUrl) == .ssh || appModel.hasGitHubToken {
                loadBranches()
            }
        }
    }

    private var statusBadge: some View {
        Text(statusText(for: currentFolder))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor(for: currentFolder.lastStatus).opacity(0.16))
            .foregroundStyle(statusColor(for: currentFolder.lastStatus))
            .clipShape(Capsule())
    }

    private var currentFolder: SyncedFolder {
        appModel.config.folders.first(where: { $0.id == draft.id }) ?? draft
    }

    private var isFocused: Bool {
        appModel.focusedFolderID == draft.id
    }

    private var statusSymbol: String {
        switch currentFolder.lastStatus {
        case .synced: return "checkmark.circle.fill"
        case .syncing, .checking: return "arrow.triangle.2.circlepath.circle.fill"
        case .paused: return "pause.circle.fill"
        case .error, .conflict: return "exclamationmark.triangle.fill"
        case .waitingForConnection, .needsAttention: return "exclamationmark.circle.fill"
        case .idle: return currentFolder.enabled ? "folder" : "pause.circle.fill"
        }
    }

    private var latestError: UserFacingError? {
        (appModel.config.folders.first(where: { $0.id == draft.id }) ?? draft).lastError
    }

    private var branchPickerOptions: [String] {
        let current = draft.branch.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "main"
        return Array(Set(remoteBranches + [current])).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func authenticatedDraft() -> SyncedFolder {
        var copy = draft
        copy.authMode = appModel.authMode(forRepositoryURL: copy.repoUrl).rawValue
        return copy
    }

    private func loadBranches() {
        isLoadingBranches = true
        let repoUrl = draft.repoUrl
        Task {
            let branches = await appModel.loadRemoteBranches(
                repoUrl: repoUrl,
                authMode: appModel.authMode(forRepositoryURL: repoUrl)
            )
            await MainActor.run {
                remoteBranches = branches
                if !branches.isEmpty, !branches.contains(draft.branch) {
                    draft.branch = branches.contains("main") ? "main" : branches[0]
                }
                isLoadingBranches = false
            }
        }
    }

    private func statusText(for folder: SyncedFolder) -> String {
        switch folder.lastStatus {
        case .idle: return "Idle"
        case .checking: return "Checking"
        case .syncing: return "Syncing"
        case .synced: return folder.lastSuccessfulSyncAt.map { "Synced \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Synced"
        case .paused: return "Paused"
        case .waitingForConnection: return "Waiting"
        case .needsAttention: return "Needs attention"
        case .error: return "Error"
        case .conflict: return "Conflict"
        }
    }

    private func statusColor(for status: SyncStatus) -> Color {
        switch status {
        case .synced: return .green
        case .syncing, .checking: return .blue
        case .paused, .idle: return .secondary
        case .waitingForConnection, .needsAttention: return .orange
        case .error, .conflict: return .red
        }
    }
}

private struct BucketSettingsRow: View {
    @Environment(AppModel.self) private var appModel
    let folder: SyncedFolder

    @State private var settings: BucketStorageSettings
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var extensionsText: String
    @State private var keepDownloadedText: String

    init(folder: SyncedFolder) {
        self.folder = folder
        let value = folder.storage ?? .defaults
        _settings = State(initialValue: value)
        _extensionsText = State(initialValue: value.offloadExtensions.joined(separator: ", "))
        _keepDownloadedText = State(initialValue: value.keepDownloadedPatterns.joined(separator: "\n"))
    }

    var body: some View {
        SettingsCard {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.blue.opacity(0.16))
                        .frame(width: 44, height: 44)
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(folder.name)
                        .font(.headline)
                    Text("S3-compatible object storage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Use bucket", isOn: $settings.enabled)
                    .toggleStyle(.switch)
            }
            .padding(18)

            SettingsDivider()

            StorageFieldRow(systemImage: "building.2", title: "Provider") {
                Picker("Provider", selection: $settings.provider) {
                    Text("Cloudflare R2").tag(StorageProvider.cloudflare)
                    Text("Amazon S3").tag(StorageProvider.aws)
                    Text("Manual").tag(StorageProvider.manual)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 470)
            }

            SettingsDivider()

            if settings.provider == .cloudflare {
                cloudflareConnectionSection
                SettingsDivider()
            } else if settings.provider == .aws {
                StorageFieldRow(systemImage: "person.crop.circle.badge.checkmark", title: "AWS account") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Connect AWS", systemImage: "person.badge.key.fill") {
                            appModel.storageMessage = "AWS connection uses IAM Identity Center. Add your organization’s access portal URL, or choose Manual for access keys."
                        }
                        Text("AWS has no universal consumer login; organization accounts connect through IAM Identity Center.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 470, alignment: .leading)
                }
                SettingsDivider()
            }

            if settings.provider == .manual {
                StorageFieldRow(systemImage: "network", title: "API endpoint") {
                    TextField("https://account.r2.cloudflarestorage.com", text: $settings.endpoint)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 470)
                }

                SettingsDivider()

                StorageFieldRow(systemImage: "shippingbox", title: "Bucket") {
                    TextField("project-assets", text: $settings.bucket)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 470)
                }

                SettingsDivider()

                StorageFieldRow(systemImage: "map", title: "Region") {
                    TextField("auto", text: $settings.region)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 470)
                }

                SettingsDivider()
            }

            StorageFieldRow(systemImage: "globe", title: "Public domain") {
                TextField("https://project-data.hakobs.com", text: $settings.publicBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 470)
            }

            SettingsDivider()

            if settings.provider == .manual {
                StorageFieldRow(systemImage: "key", title: "Access key ID") {
                    SecureField(appModel.hasStorageCredentials(folderID: folder.id) ? "Saved in Keychain" : "R2 or S3 access key", text: $accessKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 470)
                }

                SettingsDivider()

                StorageFieldRow(systemImage: "lock", title: "Secret access key") {
                    SecureField(appModel.hasStorageCredentials(folderID: folder.id) ? "Saved in Keychain" : "Secret access key", text: $secretKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 470)
                }

                SettingsDivider()
            }

            StorageFieldRow(systemImage: "arrow.up.doc", title: "Offload from") {
                Stepper("\(settings.minimumFileSizeMB) MB", value: $settings.minimumFileSizeMB, in: 1...10_000, step: 5)
                    .frame(width: 150)
            }

            SettingsDivider()

            StorageFieldRow(systemImage: "doc.badge.gearshape", title: "File extensions") {
                TextField("psd, mov, mp4, blend", text: $extensionsText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 470)
            }

            SettingsDivider()

            StorageFieldRow(systemImage: "pin", title: "Keep downloaded", alignment: .top) {
                TextEditor(text: $keepDownloadedText)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(maxWidth: 470, minHeight: 64, maxHeight: 64)
                    .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.1)))
            }

            HStack(spacing: 12) {
                Label(
                    appModel.hasStorageCredentials(folderID: folder.id) ? "Credentials saved in Keychain" : "Credentials are stored only in Keychain",
                    systemImage: appModel.hasStorageCredentials(folderID: folder.id) ? "checkmark.shield.fill" : "shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if settings.provider == .manual {
                    Link(
                        "Create Cloudflare R2 key",
                        destination: URL(string: "https://dash.cloudflare.com/?to=/:account/r2/api-tokens")!
                    )
                    .font(.caption)
                }

                Spacer()

                if appModel.hasStorageCredentials(folderID: folder.id) {
                    Button("Remove Credentials", role: .destructive) {
                        appModel.clearBucketCredentials(folderID: folder.id)
                    }
                }

                Button("Test Connection", systemImage: "checkmark.shield") {
                    save()
                    appModel.testBucketConnection(folderID: folder.id)
                }
                .disabled(appModel.isRunningStorage || !settings.enabled)

                Button("Upload Now", systemImage: "arrow.up.circle.fill") {
                    save()
                    appModel.uploadBucketFiles(folderID: folder.id)
                }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.isRunningStorage || !settings.enabled)

                Button("Save", systemImage: "square.and.arrow.down") {
                    save()
                }
                .disabled(settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || settings.bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(18)

            if let message = appModel.storageMessage {
                Label(message, systemImage: appModel.isRunningStorage ? "arrow.triangle.2.circlepath" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 16)
            }

            Text("Uploads are content-addressed and checksum-verified before the Git manifest is updated. Secrets stay in Keychain. Finder on-demand placeholders require the File Provider extension and are not enabled until that domain is installed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private var cloudflareConnectionSection: some View {
        StorageFieldRow(systemImage: "cloud.fill", title: "Cloudflare") {
            VStack(alignment: .leading, spacing: 10) {
                if appModel.cloudflareAccounts.isEmpty {
                    Button("Connect Cloudflare", systemImage: "person.badge.key.fill") {
                        appModel.connectCloudflare()
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Log in in your browser, then choose or create an R2 bucket.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Account", selection: Binding(
                        get: { appModel.selectedCloudflareAccountID ?? "" },
                        set: { appModel.selectCloudflareAccount($0) }
                    )) {
                        ForEach(appModel.cloudflareAccounts) { account in
                            Text(account.name).tag(account.id)
                        }
                    }
                    .labelsHidden()

                    if !appModel.cloudflareBuckets.isEmpty {
                        ForEach(appModel.cloudflareBuckets) { bucket in
                            HStack {
                                Label(bucket.name, systemImage: "shippingbox")
                                Spacer()
                                Button("Use Bucket") {
                                    settings.bucket = bucket.name
                                    settings.enabled = true
                                    settings.region = bucket.jurisdiction == "default" || bucket.jurisdiction == nil ? "auto" : bucket.jurisdiction!
                                    if let accountID = appModel.selectedCloudflareAccountID {
                                        let jurisdiction = bucket.jurisdiction.flatMap { $0 == "default" ? nil : $0 }
                                        settings.endpoint = "https://\(accountID)\(jurisdiction.map { ".\($0)" } ?? "").r2.cloudflarestorage.com"
                                    }
                                    appModel.useCloudflareBucket(bucket, folderID: folder.id)
                                }
                            }
                        }
                    }

                    HStack {
                        TextField("new-bucket-name", text: $settings.bucket)
                            .textFieldStyle(.roundedBorder)
                        Button("Create Bucket") {
                            appModel.createCloudflareBucket(name: settings.bucket, folderID: folder.id)
                        }
                        .disabled(settings.bucket.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                    }
                }
            }
            .frame(maxWidth: 470, alignment: .leading)
        }
    }

    private func save() {
        settings.endpoint = settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.bucket = settings.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.region = settings.region.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.publicBaseURL = settings.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.offloadExtensions = extensionsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        settings.keepDownloadedPatterns = keepDownloadedText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        appModel.saveBucketStorage(
            folderID: folder.id,
            settings: settings,
            accessKey: accessKey,
            secretKey: secretKey
        )
        accessKey = ""
        secretKey = ""
    }
}

private struct AddFolderSheet: View {
    @Environment(AppModel.self) private var appModel
    @Binding var isPresented: Bool

    @State private var selectedURL: URL?
    @State private var repoUrl = ""
    @State private var branch = "main"
    @State private var interval = 15
    @State private var errorMessage: String?
    @State private var isTesting = false
    @State private var gitHubAuthorization: GitHubDeviceAuthorization?
    @State private var isConnectingGitHub = false
    @State private var gitHubConnectionMessage: String?
    @State private var remoteBranches: [String] = []
    @State private var isLoadingBranches = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add Folder")
                    .font(.title.bold())
                Text("Choose a local folder and connect it to a GitHub repository.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SettingsCard {
                SettingsFieldRow(systemImage: "folder", title: "Local folder") {
                    HStack(spacing: 12) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(selectedURL?.lastPathComponent ?? "No folder selected")
                                .font(.headline)
                            if let selectedURL {
                                Text(selectedURL.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }

                        Button("Choose...", systemImage: "folder.badge.plus") {
                            selectedURL = FolderAccessService().pickFolder()
                        }
                    }
                }

                SettingsDivider()

                SettingsFieldRow(systemImage: "link", title: "Repository URL") {
                    TextField("https://github.com/owner/repo.git", text: $repoUrl)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 360)
                        .onChange(of: repoUrl) { _, _ in
                            remoteBranches = []
                        }
                }

                if !appModel.hasGitHubToken && appModel.authMode(forRepositoryURL: repoUrl) == .githubToken {
                    SettingsDivider()

                    SettingsFieldRow(systemImage: "key", title: "GitHub") {
                        VStack(alignment: .trailing, spacing: 10) {
                            Button(isConnectingGitHub ? "Waiting for GitHub..." : "Connect GitHub", systemImage: "link") {
                                connectGitHub()
                            }
                            .disabled(isConnectingGitHub)

                            if let gitHubAuthorization {
                                GitHubDeviceCodeRow(authorization: gitHubAuthorization)
                                    .frame(width: 360)
                            }

                            if let gitHubConnectionMessage {
                                Text(gitHubConnectionMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                SettingsDivider()

                SettingsFieldRow(systemImage: "point.3.connected.trianglepath.dotted", title: "Branch") {
                    HStack(spacing: 10) {
                        Picker("Branch", selection: $branch) {
                            ForEach(branchPickerOptions, id: \.self) { branch in
                                Text(branch).tag(branch)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)

                        Button {
                            loadBranches()
                        } label: {
                            Image(systemName: isLoadingBranches ? "hourglass" : "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Load branches from GitHub")
                        .disabled(isLoadingBranches || repoUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (appModel.authMode(forRepositoryURL: repoUrl) == .githubToken && !appModel.hasGitHubToken))
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                SettingsDivider()

                SettingsFieldRow(systemImage: "clock", title: "Sync Interval") {
                    Picker("Interval", selection: $interval) {
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("60 minutes").tag(60)
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                Button(isTesting ? "Testing…" : "Test, Add and Sync") {
                    addAndSync()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isTesting || selectedURL == nil || repoUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (appModel.authMode(forRepositoryURL: repoUrl) == .githubToken && !appModel.hasGitHubToken))
            }
        }
        .padding()
        .frame(width: 680)
    }

    private func addAndSync() {
        guard let selectedURL else { return }
        isTesting = true
        Task {
            let authMode = appModel.authMode(forRepositoryURL: repoUrl)
            let hasAccess = await appModel.testGitHubAccess(repoUrl: repoUrl, authMode: authMode)
            await MainActor.run {
                isTesting = false
                guard hasAccess else {
                    errorMessage = appModel.lastMessage
                    return
                }
                do {
                    let id = try appModel.addFolder(localURL: selectedURL, repoUrl: repoUrl, authMode: authMode, branch: branch, syncIntervalMinutes: interval)
                    isPresented = false
                    appModel.syncNow(folderID: id)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func connectGitHub() {
        isConnectingGitHub = true
        gitHubAuthorization = nil
        gitHubConnectionMessage = "Requesting a GitHub sign-in code…"

        Task {
            do {
                let authorization = try await appModel.requestGitHubConnectionCode()
                await MainActor.run {
                    gitHubAuthorization = authorization
                    gitHubConnectionMessage = "Enter this code on GitHub, then approve GitFolder."
                    NSWorkspace.shared.open(authorization.verificationURI)
                }
                let connected = await appModel.finishGitHubConnection(authorization)
                await MainActor.run {
                    isConnectingGitHub = false
                    if connected {
                        gitHubAuthorization = nil
                        gitHubConnectionMessage = "GitHub connected."
                    } else {
                        gitHubConnectionMessage = appModel.lastMessage
                    }
                }
            } catch {
                await MainActor.run {
                    isConnectingGitHub = false
                    appModel.lastMessage = "GitHub connection failed: \(error.localizedDescription)"
                    gitHubConnectionMessage = appModel.lastMessage
                }
            }
        }
    }

    private var branchPickerOptions: [String] {
        let current = branch.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "main"
        return Array(Set(remoteBranches + [current])).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func loadBranches() {
        isLoadingBranches = true
        let repoUrl = repoUrl
        Task {
            let branches = await appModel.loadRemoteBranches(
                repoUrl: repoUrl,
                authMode: appModel.authMode(forRepositoryURL: repoUrl)
            )
            await MainActor.run {
                remoteBranches = branches
                if !branches.isEmpty, !branches.contains(branch) {
                    branch = branches.contains("main") ? "main" : branches[0]
                }
                isLoadingBranches = false
            }
        }
    }
}

private enum GitHubAuthSetupMode: Hashable {
    case connect
    case pat
}

private struct SettingsPane<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.largeTitle.weight(.bold))
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                content
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 32)
        }
        .background(Color.black.opacity(0.92))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

private struct SettingsFieldRow<Content: View>: View {
    let systemImage: String
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 26)

            Text(title)
                .font(.headline)

            Spacer(minLength: 24)

            content
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

private struct StorageFieldRow<Content: View>: View {
    let systemImage: String
    let title: String
    var alignment: VerticalAlignment = .center
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: alignment, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 22)

            Text(title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(width: 142, alignment: .leading)

            content
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

private struct FolderFieldRow<Content: View>: View {
    let systemImage: String
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 26)

            Text(title)
                .font(.headline)
                .frame(width: 160, alignment: .leading)

            Spacer(minLength: 20)

            content
                .frame(minWidth: 0, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .overlay(Color.white.opacity(0.08))
            .padding(.leading, 60)
    }
}

private struct AppLogoView: View {
    let size: CGFloat

    var body: some View {
        Image("GitFolderLogo")
            .resizable()
            .renderingMode(.original)
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case sync
    case github
    case identity
    case storage
    case folders

    var id: Self { self }

    var title: String {
        switch self {
        case .sync: return "Sync"
        case .github: return "GitHub"
        case .identity: return "Git Identity"
        case .storage: return "Storage"
        case .folders: return "Folders"
        }
    }

    var systemImage: String {
        switch self {
        case .sync: return "arrow.triangle.2.circlepath"
        case .github: return "key"
        case .identity: return "person.text.rectangle"
        case .storage: return "externaldrive.connected.to.line.below"
        case .folders: return "folder"
        }
    }
}

private struct MacSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private enum SettingsWindowMetrics {
    static var preferredContentHeight: CGFloat {
        min(840, maximumContentHeight)
    }

    static var maximumContentHeight: CGFloat {
        guard let screen = NSScreen.main else { return 760 }
        return max(520, screen.visibleFrame.height - 72)
    }
}

private struct GitHubDeviceCodeRow: View {
    let authorization: GitHubDeviceAuthorization
    @State private var copiedCode = false

    var body: some View {
        HStack(spacing: 8) {
            Text(authorization.userCode)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(authorization.userCode, forType: .string)
                copiedCode = true
            } label: {
                Image(systemName: copiedCode ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(copiedCode ? "Copied" : "Copy code")

            Spacer()

            Button("Open GitHub") {
                NSWorkspace.shared.open(authorization.verificationURI)
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
