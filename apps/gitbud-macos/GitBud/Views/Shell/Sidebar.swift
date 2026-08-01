import GitBudCore
import GitKit
import SwiftUI

/// Four destinations and the repository's current state. Nothing here performs git work —
/// verbs live on the items they act on.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: GitBudWorkspaceMode

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.repositoryName)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Text(branchLabel)
                    .font(.caption)
                    .foregroundStyle(GitBudTheme.secondaryText)
                    .lineLimit(2)
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)

            VStack(spacing: 5) {
                ForEach(GitBudWorkspaceMode.allCases) { mode in
                    Button {
                        selection = mode
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 22)
                            Text(mode.title)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if let badge = badge(for: mode) {
                                Text(badge)
                                    .font(.caption2.monospaced().weight(.bold))
                                    .foregroundStyle(GitBudTheme.secondaryText)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .gitBudPanelRow(isSelected: selection == mode, cornerRadius: 8, baseOpacity: 0.0)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)

            if model.hasConflicts {
                Label("\(model.conflicts.count) conflicts need resolution", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.horizontal, 10)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                StatusPill(
                    title: model.worktreeFiles.isEmpty ? "Clean tree" : "\(model.worktreeFiles.count) changes",
                    color: model.worktreeFiles.isEmpty ? .green : .orange
                )
                if let summary = model.branchSummary {
                    StatusPill(
                        title: "Ahead \(summary.ahead) / Behind \(summary.behind)",
                        color: summary.behind > 0 ? .orange : GitBudTheme.secondaryText
                    )
                }
                if model.isCurrentBranchProtected {
                    StatusPill(title: "Protected branch", color: .orange)
                }
            }
            .padding(12)
        }
        .background(GitBudTheme.panel)
    }

    private var branchLabel: String {
        guard let summary = model.branchSummary else { return model.statusMessage }
        return summary.currentBranch ?? "Detached HEAD"
    }

    /// Only counts worth acting on. A commit count next to "History" is noise.
    private func badge(for mode: GitBudWorkspaceMode) -> String? {
        switch mode {
        case .history:
            return nil
        case .changes:
            return model.worktreeFiles.isEmpty ? nil : "\(model.worktreeFiles.count)"
        case .branches:
            return model.branches.isEmpty ? nil : "\(model.branches.count)"
        case .pullRequests:
            return model.providerPullRequests.isEmpty ? nil : "\(model.providerPullRequests.count)"
        }
    }
}
