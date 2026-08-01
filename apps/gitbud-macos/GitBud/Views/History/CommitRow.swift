import AppKit
import GitBudCore
import GitKit
import SwiftUI

/// One commit in the graph. Click to focus, ⌘-click to add to the selection, ⇧-click to
/// extend it, right-click for what you can do to it.
struct CommitRow: View {
    @Environment(AppModel.self) private var model
    let row: GitGraphRow
    let laneCount: Int
    @Binding var pending: GitBudAction?

    private var commit: GitCommitNode { row.commit }
    private var isFocused: Bool { model.focusedCommitID == commit.id }
    private var isSelected: Bool { model.selectedCommitIDs.contains(commit.id) }

    var body: some View {
        HStack(spacing: 10) {
            CommitGraphCell(row: row, laneCount: laneCount, isSelected: isSelected)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(commit.subject)
                        .font(.subheadline.weight(isFocused ? .semibold : .regular))
                        .lineLimit(1)
                    ForEach(commit.decorations.prefix(3), id: \.self) { decoration in
                        Text(decoration)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                CommitGraphCell.color(row.colorIndex).opacity(0.20),
                                in: Capsule()
                            )
                    }
                }
                HStack(spacing: 8) {
                    Text(commit.shortID)
                        .font(.caption2.monospaced().weight(.bold))
                    Text(commit.author)
                        .font(.caption2)
                    Text(commit.authorDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                }
                .foregroundStyle(GitBudTheme.secondaryText)
            }

            Spacer(minLength: 0)

            if isSelected, let position = model.selectedCommitIDs.firstIndex(of: commit.id) {
                Text("\(position + 1)")
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(GitBudTheme.secondaryText)
                    .frame(width: 20, height: 20)
                    .background(.white.opacity(0.10), in: Circle())
            }
        }
        .padding(.horizontal, 12)
        .frame(height: CommitGraphCell.rowHeight)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture { handleTap() }
        .contextMenu {
            ActionMenuItems(actions: GitBudActions.commit(commit, model: model), pending: $pending)
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isFocused {
            Color.accentColor.opacity(0.20)
        } else if isSelected {
            Color.accentColor.opacity(0.10)
        } else {
            Color.clear
        }
    }

    private func handleTap() {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            model.toggleCommitSelection(commit)
            model.focusedCommitID = commit.id
        } else if flags.contains(.shift) {
            model.extendCommitSelection(to: commit)
        } else {
            model.selectCommit(commit)
        }
    }
}
