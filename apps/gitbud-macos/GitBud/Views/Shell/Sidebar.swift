import GitBudCore
import GitKittieKit
import SwiftUI

/// The places in a repository and where it stands, drawn like the Tasks sidebar: a list on
/// the family's sidebar colour, counts as badges, and what to add or change in a footer.
/// Nothing here performs git work — verbs live on the items they act on.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: GitBudWorkspaceMode

    var body: some View {
        List(selection: Binding<GitBudWorkspaceMode?>(
            get: { selection },
            set: { if let mode = $0 { selection = mode } }
        )) {
            Section {
                ForEach(GitBudWorkspaceMode.allCases) { mode in
                    row(mode)
                        .tag(mode)
                }
            }

            Section(model.repositoryName) {
                stateRow(
                    model.branchSummary?.currentBranch ?? "Detached HEAD",
                    symbol: "arrow.triangle.branch",
                    tint: .accentColor
                ) {
                    if model.isCurrentBranchProtected {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("Protected branch: rewritten history is never force-pushed here")
                    }
                }
                if let summary = model.branchSummary {
                    stateRow(
                        summary.upstream ?? "No upstream",
                        symbol: "icloud",
                        tint: .secondary
                    ) {
                        if summary.ahead > 0 { CountBadge(count: summary.ahead, color: .accentColor).help("\(summary.ahead) to push") }
                        if summary.behind > 0 { CountBadge(count: summary.behind, color: .orange).help("\(summary.behind) to pull") }
                    }
                }
                stateRow(
                    model.worktreeFiles.isEmpty ? "Clean working copy" : "Uncommitted changes",
                    symbol: model.worktreeFiles.isEmpty ? "checkmark.circle" : "pencil.circle",
                    tint: model.worktreeFiles.isEmpty ? .green : .orange
                ) { EmptyView() }
                if model.hasConflicts {
                    stateRow(
                        "\(model.conflicts.count) conflict\(model.conflicts.count == 1 ? "" : "s") to resolve",
                        symbol: "exclamationmark.triangle.fill",
                        tint: .orange
                    ) { EmptyView() }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(GitBudTheme.sidebar.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private func row(_ mode: GitBudWorkspaceMode) -> some View {
        HStack(spacing: 10) {
            Image(systemName: mode.icon)
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            Text(mode.title)
                .font(.body.weight(.medium))
            Spacer(minLength: 4)
            if let count = count(for: mode) {
                CountBadge(count: count, color: mode == .changes ? .orange : nil)
            }
        }
        .padding(.vertical, 3)
    }

    /// A line of state under the repository: what it is, and a badge if it wants attention.
    private func stateRow<Accessory: View>(
        _ title: String,
        symbol: String,
        tint: Color,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(tint)
                .frame(width: 20)
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            accessory()
        }
        .padding(.vertical, 2)
        .selectionDisabled()
    }

    /// Under the list: open another repository on the left, settings on the right.
    private var footer: some View {
        HStack {
            Button {
                model.openRepositoryPanel()
            } label: {
                Label("Open Repository", systemImage: "plus").font(.callout)
            }
            .buttonStyle(.plain)
            .help("Open another repository (⌘O)")
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape").font(.callout)
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Only counts worth acting on. A commit count next to "History" is noise.
    private func count(for mode: GitBudWorkspaceMode) -> Int? {
        switch mode {
        case .history:
            return nil
        case .changes:
            return model.worktreeFiles.isEmpty ? nil : model.worktreeFiles.count
        case .branches:
            return model.branches.isEmpty ? nil : model.branches.count
        case .pullRequests:
            return model.providerPullRequests.isEmpty ? nil : model.providerPullRequests.count
        }
    }
}
