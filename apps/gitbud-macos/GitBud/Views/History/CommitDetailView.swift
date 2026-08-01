import GitBudCore
import GitKit
import SwiftUI

/// What you clicked on: the message, its files, its diff, and the verbs that apply.
/// No working-tree stager, no settings — just this commit.
struct CommitDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var pending: GitBudAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let commit = model.focusedCommit {
                header(commit)
                Divider().overlay(.white.opacity(0.08))

                if model.selectedCommitIDs.count > 1 {
                    plannedOrder
                    Divider().overlay(.white.opacity(0.08))
                }

                HSplitView {
                    FileList()
                        .frame(minWidth: 200, idealWidth: 240)
                    DiffView()
                        .frame(minWidth: 280)
                }
            } else {
                EmptyPanel(
                    title: "Select a commit",
                    message: "Choose a commit in the graph to inspect its files and diff."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .actionSheet(pending: $pending)
    }

    private func header(_ commit: GitCommitNode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(commit.subject)
                        .font(.title3.weight(.semibold))
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Text("\(commit.author) · \(commit.shortID) · \(commit.authorDate.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(GitBudTheme.secondaryText)
                        .textSelection(.enabled)
                }
                Spacer()
                actionToolbar(commit)
            }

            if !commit.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(commit.body)
                    .font(.callout)
                    .foregroundStyle(GitBudTheme.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }

    /// The two or three verbs worth a permanent button. Everything else is a right-click
    /// away, or in ⌘K.
    private func actionToolbar(_ commit: GitCommitNode) -> some View {
        let actions = GitBudActions.commit(commit, model: model)
        let primary = actions.filter { ["commit.rewriteMessage", "commit.squash", "commit.revert"].contains($0.id) }

        return HStack(spacing: 6) {
            ForEach(primary) { action in
                Button {
                    if action.needsSheet { pending = action } else { action.perform("") }
                } label: {
                    Image(systemName: action.icon)
                }
                .help(action.isEnabled ? action.title : (action.disabledReason ?? action.title))
                .disabled(!action.isEnabled)
            }

            Menu {
                ActionMenuItems(actions: actions, pending: $pending)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 34)
        }
    }

    /// When several commits are selected, show the order a rewrite would apply them in.
    private var plannedOrder: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(model.selectedCommitIDs.count) commits selected")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(GitBudTheme.secondaryText)
                Spacer()
                if let preview = model.rewritePreview {
                    Text("Base \(String(preview.baseCommitID.prefix(8)))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(GitBudTheme.secondaryText)
                }
            }
            ForEach(Array(model.selectedCommitIDs.enumerated()), id: \.element) { index, commitID in
                let commit = model.commits.first { $0.id == commitID }
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(GitBudTheme.secondaryText)
                        .frame(width: 18)
                    Text(commit?.subject ?? String(commitID.prefix(8)))
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Text(commit?.shortID ?? "")
                        .font(.caption2.monospaced())
                        .foregroundStyle(GitBudTheme.secondaryText)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .gitBudPanelRow(isSelected: model.focusedCommitID == commitID, cornerRadius: 6, baseOpacity: 0.03)
            }
        }
        .padding(16)
    }
}
