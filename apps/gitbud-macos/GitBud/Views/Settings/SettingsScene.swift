import GitBudCore
import GitKit
import SwiftUI

/// ⌘, — a real macOS Settings window rather than a sidebar tab. Everything here is
/// configuration, not a place you navigate to while working.
struct SettingsScene: View {
    var body: some View {
        TabView {
            AccountsTab()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            MagicTab()
                .tabItem { Label("Magic", systemImage: "sparkles") }
            SafetyTab()
                .tabItem { Label("Safety", systemImage: "lock.shield") }
            RepositoryTab()
                .tabItem { Label("Repository", systemImage: "shippingbox") }
        }
        .frame(width: 520, height: 460)
    }
}

struct AccountsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Connect") {
                TextField("OAuth client ID", text: $model.providerOAuthClientID)
                HStack(spacing: 8) {
                    Button("Connect") { model.requestProviderConnectionCode() }
                        .disabled(
                            model.providerOAuthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            model.isConnectingProviderAccount
                        )
                    Button("Finish") { model.finishProviderConnection() }
                        .disabled(model.providerOAuthAuthorization == nil || model.isConnectingProviderAccount)
                    if model.isConnectingProviderAccount {
                        ProgressView().controlSize(.small)
                    }
                }
                if let authorization = model.providerOAuthAuthorization {
                    HStack {
                        Text(authorization.userCode)
                            .font(.callout.monospaced().weight(.bold))
                            .textSelection(.enabled)
                        Spacer()
                        Link("Open GitHub", destination: authorization.verificationURI)
                    }
                }
                if let login = model.providerLogin {
                    Label("Signed in as \(login)", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }

            Section("Token") {
                SecureField("Access token", text: $model.remoteAccessToken)
                HStack(spacing: 8) {
                    Button("Save Token") { model.saveProviderAccessToken() }
                        .disabled(model.remoteAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Clear", role: .destructive) { model.clearProviderAccessToken() }
                    Spacer()
                    Text("Stored in the macOS Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Repository") {
                Button("Load Repositories") { model.loadProviderRepositories() }
                    .disabled(
                        model.remoteAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        model.isLoadingRemoteRepositories
                    )
                if !model.providerRepositories.isEmpty {
                    Picker("Active repository", selection: $model.selectedProviderRepositoryID) {
                        ForEach(model.providerRepositories) { repository in
                            Text(repository.fullName).tag(Optional(repository.id))
                        }
                    }
                    .onChange(of: model.selectedProviderRepositoryID) { _, repositoryID in
                        guard let repositoryID,
                              let repository = model.providerRepositories.first(where: { $0.id == repositoryID })
                        else { return }
                        model.selectProviderRepository(repository)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct MagicTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Provider") {
                Picker("Provider", selection: $model.magicProvider) {
                    ForEach(AIPontProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                TextField("Model", text: $model.magicModel)
                TextField("Endpoint", text: $model.magicEndpoint)
                SecureField("API key", text: $model.magicAPIKey)
                Button("Save Magic Settings") { model.saveMagicSettings() }
            }

            Section {
                Text("Your key goes straight from this Mac to the provider you choose. GitBud has no server and stores the key in the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct SafetyTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Protected branches") {
                Text("Rewritten history is never force-pushed to a branch matching these patterns. One per line; * is a wildcard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $model.protectedBranchPatternsText)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 120)
                Button("Save Protected Branches") { model.saveProtectedBranchPolicy() }
            }

            Section("How rewrites are protected") {
                Label("A safety branch is cut automatically before every rewrite.", systemImage: "checkmark.shield")
                Label("Rewrites require a clean working tree.", systemImage: "checkmark.shield")
                Label("Publishing rewritten history uses --force-with-lease and a typed confirmation.", systemImage: "checkmark.shield")
            }
            .font(.caption)
        }
        .formStyle(.grouped)
    }
}

/// Remotes, linked worktrees, and submodules — real features, but ones you configure
/// occasionally rather than reach for while reading history.
struct RepositoryTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Remotes") {
                ForEach(model.remotes) { remote in
                    remoteRow(remote)
                }
                HStack(spacing: 8) {
                    TextField("Name", text: $model.newRemoteName).frame(width: 100)
                    TextField("URL", text: $model.newRemoteURLString)
                    Button("Add") { model.addRemote() }
                        .disabled(
                            model.newRemoteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            model.newRemoteURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            model.isRunningRemoteOperation
                        )
                }
            }

            Section("Linked worktrees") {
                ForEach(model.linkedWorktrees) { worktree in
                    linkedWorktreeRow(worktree)
                }
                HStack(spacing: 8) {
                    TextField("Path", text: $model.newLinkedWorktreePath)
                    TextField("Branch", text: $model.newLinkedWorktreeBranch).frame(width: 130)
                    Button("Add") { model.addLinkedWorktree() }
                        .disabled(
                            model.newLinkedWorktreePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            model.newLinkedWorktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            model.isRunningLinkedWorktreeOperation
                        )
                }
            }

            Section("Submodules") {
                if model.submodules.isEmpty {
                    Text("No submodules.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.submodules) { submodule in
                        submoduleRow(submodule)
                    }
                    Button("Update All") { model.updateAllSubmodules() }
                        .disabled(model.isRunningSubmoduleOperation)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func remoteRow(_ remote: GitRemote) -> some View {
        HStack {
            Text(remote.name).font(.callout.weight(.semibold))
            Text(remote.fetchURL ?? remote.pushURL ?? "no URL")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Remove", role: .destructive) {
                model.selectedRemoteName = remote.name
                model.removeSelectedRemote()
            }
            .disabled(model.isRunningRemoteOperation)
        }
    }

    private func linkedWorktreeRow(_ worktree: GitLinkedWorktree) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(worktree.path).font(.caption).lineLimit(1)
                Text(worktree.branch ?? "detached")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove", role: .destructive) {
                model.selectedLinkedWorktreePath = worktree.path
                model.removeSelectedLinkedWorktree()
            }
            .disabled(model.isRunningLinkedWorktreeOperation)
        }
    }

    private func submoduleRow(_ submodule: GitSubmodule) -> some View {
        HStack {
            Text(submodule.path).font(.caption).lineLimit(1)
            Spacer()
            Button("Update") {
                model.selectedSubmodulePath = submodule.path
                model.updateSelectedSubmodule()
            }
            .disabled(model.isRunningSubmoduleOperation)
        }
    }
}
