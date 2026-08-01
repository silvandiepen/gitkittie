import GitBudCore
import GitKit
import SwiftUI

/// Tags. Always visible — the old UI only rendered this section while the working tree
/// was dirty, which was exactly when every button in it was disabled.
struct TagSection: View {
    @Environment(AppModel.self) private var model
    @Binding var pending: GitBudAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.tags.isEmpty {
                Text("No tags yet.")
                    .font(.caption)
                    .foregroundStyle(GitBudTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ForEach(model.tags) { tag in
                    row(tag)
                }
            }

            if let commit = model.focusedCommit {
                Button {
                    pending = newTagAction(on: commit)
                } label: {
                    Label("New tag on \(commit.shortID)", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 4)
                .disabled(!model.worktreeFiles.isEmpty)
                .help(model.worktreeFiles.isEmpty
                      ? "Tag the commit selected in History"
                      : "Commit or stash your changes before tagging")

                if !model.worktreeFiles.isEmpty {
                    Text("Tagging needs a clean working tree.")
                        .font(.caption2)
                        .foregroundStyle(GitBudTheme.secondaryText)
                }
            }
        }
    }

    private func row(_ tag: GitTag) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "tag")
                .font(.system(size: 12))
                .foregroundStyle(GitBudTheme.secondaryText)
                .frame(width: 20)
            Text(tag.name)
                .font(.subheadline)
            Spacer(minLength: 0)
            Text(tag.shortCommitID)
                .font(.caption2.monospaced())
                .foregroundStyle(GitBudTheme.secondaryText)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .gitBudPanelRow(isSelected: model.selectedTagName == tag.name, cornerRadius: 8, baseOpacity: 0.035)
        .onTapGesture { model.selectedTagName = tag.name }
        .contextMenu {
            Button {
                gitBudCopyToPasteboard(tag.name)
            } label: {
                Label("Copy Name", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                model.selectedTagName = tag.name
                model.deleteSelectedTag()
            } label: {
                Label("Delete Tag", systemImage: "trash")
            }
            .disabled(!model.worktreeFiles.isEmpty || model.hasConflicts)
        }
    }

    private func newTagAction(on commit: GitCommitNode) -> GitBudAction {
        GitBudAction(
            id: "tag.create",
            title: "New Tag",
            icon: "tag",
            interaction: .input(
                title: "Tag \(commit.shortID) — \(commit.subject)",
                placeholder: "v1.0.0",
                defaultValue: "",
                verb: "Create Tag"
            ),
            perform: { name in
                model.newTagName = name
                model.createTagFromSelectedCommit()
            }
        )
    }
}
