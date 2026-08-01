import GitBudCore
import GitKit
import SwiftUI

/// The welcome screen. Opening and cloning live here; account setup lives in Settings,
/// so this screen stays about getting into a repository.
struct NoRepositoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                Spacer(minLength: 24)

                VStack(alignment: .leading, spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(0.18))
                            .frame(width: 56, height: 56)
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Open a repository")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("Start from a local checkout or clone a remote URL.")
                            .font(.title3)
                            .foregroundStyle(GitBudTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button {
                    model.openRepositoryPanel()
                } label: {
                    Label("Open Local Repo", systemImage: "folder")
                        .frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                VStack(alignment: .leading, spacing: 12) {
                    Text("What GitBud is good at")
                        .font(.headline.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                        NoRepositoryCapability(
                            icon: "arrow.triangle.2.circlepath",
                            title: "Rebase visually",
                            detail: "Squash, reorder, drop, split, and undo with safety refs."
                        )
                        NoRepositoryCapability(
                            icon: "doc.text.magnifyingglass",
                            title: "Inspect history",
                            detail: "A real commit graph, diffs, file history, blame, and conflicts."
                        )
                        NoRepositoryCapability(
                            icon: "sparkles",
                            title: "Magic messages",
                            detail: "BYOK AIPont suggestions reviewed before they touch git."
                        )
                        NoRepositoryCapability(
                            icon: "network",
                            title: "Remote workflows",
                            detail: "Provider repos, draft PRs, review state, and direct git sync."
                        )
                    }
                }

                Spacer(minLength: 24)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            Divider().overlay(.white.opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SectionHeader(title: "Clone", icon: "tray.and.arrow.down")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Clone by URL")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(GitBudTheme.secondaryText)
                        TextField("https://github.com/owner/repo.git", text: $model.remoteURLString)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            model.cloneRemoteRepository()
                        } label: {
                            if model.isCloningRemote {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(maxWidth: .infinity)
                            } else {
                                Label("Clone Remote", systemImage: "square.and.arrow.down")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(
                            model.remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            model.isCloningRemote
                        )
                    }
                    .panelCard()

                    if model.providerRepositories.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Provider account")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(GitBudTheme.secondaryText)
                            Text("Connect an account in Settings to browse and clone your remote repositories.")
                                .font(.caption)
                                .foregroundStyle(GitBudTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                openSettings()
                            } label: {
                                Label("Open Settings", systemImage: "gearshape")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .panelCard()
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.providerLogin.map { "Signed in as \($0)" } ?? "Your repositories")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(GitBudTheme.secondaryText)
                            Picker("Repository", selection: $model.selectedProviderRepositoryID) {
                                ForEach(model.providerRepositories) { repository in
                                    Text(repository.fullName).tag(Optional(repository.id))
                                }
                            }
                            .labelsHidden()
                            .onChange(of: model.selectedProviderRepositoryID) { _, repositoryID in
                                guard let repositoryID,
                                      let repository = model.providerRepositories.first(where: { $0.id == repositoryID })
                                else { return }
                                model.selectProviderRepository(repository)
                            }
                            Button {
                                model.cloneSelectedProviderRepository()
                            } label: {
                                Label("Clone Selected Repo", systemImage: "square.and.arrow.down.on.square")
                                    .frame(maxWidth: .infinity)
                            }
                            .disabled(model.selectedProviderRepository == nil || model.isCloningRemote)
                        }
                        .panelCard()
                    }
                }
                .padding(18)
            }
            .frame(width: 340)
            .background(GitBudTheme.panel)
        }
    }
}

private struct NoRepositoryCapability: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(GitBudTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GitBudTheme.cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(GitBudTheme.cardBorder)
        }
    }
}
