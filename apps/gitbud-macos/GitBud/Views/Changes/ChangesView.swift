import GitBudCore
import GitKit
import SwiftUI

/// The working copy. Pick files, write a message, commit. Stashes live at the bottom
/// because that is where you look for them, not because they need a tab.
struct ChangesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().overlay(.white.opacity(0.08))
                WorkingCopyList()
                Divider().overlay(.white.opacity(0.08))
                commitBox
                Divider().overlay(.white.opacity(0.08))
                StashSection()
            }
            .frame(minWidth: 320, idealWidth: 400, maxWidth: 520)

            DiffView()
                .frame(minWidth: 360)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Changes")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(model.worktreeFiles.isEmpty
                     ? "Working tree is clean"
                     : "\(model.worktreeFiles.count) changed · \(model.selectedWorktreePaths.count) selected")
                    .font(.caption)
                    .foregroundStyle(GitBudTheme.secondaryText)
            }
            Spacer()
            if model.isUpdatingWorktree || model.isCommittingWorktree {
                ProgressView().controlSize(.small)
            }
        }
        .padding(16)
    }

    private var commitBox: some View {
        @Bindable var model = model

        return VStack(alignment: .leading, spacing: 8) {
            TextField("Commit message", text: $model.worktreeCommitMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)

            HStack(spacing: 8) {
                Button {
                    model.commitSelectedWorktreePaths()
                } label: {
                    Label("Commit \(model.selectedWorktreePaths.count) file\(model.selectedWorktreePaths.count == 1 ? "" : "s")", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.selectedWorktreePaths.isEmpty ||
                    model.worktreeCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    model.isCommittingWorktree ||
                    model.hasConflicts
                )

                Button {
                    model.amendHeadWithSelectedWorktreePaths()
                } label: {
                    Label("Amend", systemImage: "arrow.up.doc")
                }
                .help("Fold the selected files into the previous commit")
                .disabled(model.selectedWorktreePaths.isEmpty || model.isCommittingWorktree || model.hasConflicts)

                Button {
                    model.draftMagicCommitMessage()
                } label: {
                    if model.isDraftingMagic {
                        ProgressView().controlSize(.small).frame(width: 18)
                    } else {
                        Image(systemName: "sparkles")
                    }
                }
                .help(model.magicAPIKey.isEmpty
                      ? "Add an AI key in Settings to draft messages"
                      : "Draft a commit message from the selected changes")
                .disabled(model.magicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isDraftingMagic)
            }
        }
        .padding(16)
    }
}
