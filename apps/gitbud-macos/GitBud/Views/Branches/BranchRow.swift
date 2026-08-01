import GitBudCore
import GitKittieKit
import SwiftUI

/// One branch. Double-click to switch, right-click for everything else.
struct BranchRow: View {
    @Environment(AppModel.self) private var model
    let branch: GitBranch
    @Binding var pending: GitBudAction?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(branch.isCurrent ? Color.accentColor : GitBudTheme.secondaryText)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(branch.shortName)
                    .font(.subheadline.weight(branch.isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                Text(branch.subject)
                    .font(.caption)
                    .foregroundStyle(GitBudTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let upstream = branch.upstream {
                Text(upstream)
                    .font(.caption2)
                    .foregroundStyle(GitBudTheme.secondaryText)
                    .lineLimit(1)
            }

            VStack(alignment: .trailing, spacing: 3) {
                Text(branch.updatedDescription.isEmpty ? "—" : branch.updatedDescription)
                    .font(.caption2)
                Text(branch.shortCommitID)
                    .font(.caption2.monospaced())
            }
            .foregroundStyle(GitBudTheme.secondaryText)
        }
        .padding(11)
        .contentShape(Rectangle())
        .gitBudPanelRow(isSelected: branch.isCurrent, cornerRadius: 8, baseOpacity: 0.035)
        .onTapGesture(count: 2) {
            guard !(branch.kind == .local && branch.isCurrent) else { return }
            model.checkoutBranch(branch)
        }
        .onTapGesture { model.selectBranchOperationTarget(branch) }
        .contextMenu {
            ActionMenuItems(actions: GitBudActions.branch(branch, model: model), pending: $pending)
        }
        .help(helpText)
    }

    private var icon: String {
        if branch.isCurrent { return "checkmark.circle.fill" }
        return branch.kind == .local ? "circle" : "icloud"
    }

    private var helpText: String {
        var parts = [branch.kind == .local ? "Local branch" : "Remote branch", branch.shortCommitID]
        if branch.kind == .remote {
            parts.append("double-click to create a local tracking branch")
        } else if !branch.isCurrent {
            parts.append("double-click to switch")
        }
        return parts.joined(separator: " · ")
    }
}
