import GitBudCore
import GitKit
import SwiftUI

/// Changed files in the working tree. Tick what you want to commit; right-click for
/// stage, unstage, and discard.
struct WorkingCopyList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.worktreeFiles.isEmpty {
                EmptyPanel(
                    title: "Nothing to commit",
                    message: "Edit some files and they will show up here."
                )
                .frame(maxHeight: 220)
            } else {
                HStack(spacing: 8) {
                    Button(allSelected ? "Deselect All" : "Select All") {
                        toggleAll()
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.worktreeFiles) { file in
                            row(file)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(minHeight: 140, maxHeight: 320)
            }
        }
    }

    private func row(_ file: GitWorktreeFile) -> some View {
        let isSelected = model.selectedWorktreePaths.contains(file.path)

        return HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundStyle(isSelected ? Color.accentColor : GitBudTheme.secondaryText)
            Text(file.displayStatus)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(statusColor(file))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.path)
                    .font(.caption)
                    .lineLimit(1)
                if let original = file.originalPath {
                    Text("was \(original)")
                        .font(.caption2)
                        .foregroundStyle(GitBudTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .gitBudPanelRow(isSelected: isSelected, cornerRadius: 8, baseOpacity: 0.045)
        .onTapGesture { model.toggleWorktreePath(file) }
        .contextMenu {
            Button {
                selectOnly(file)
                model.stageSelectedWorktreePaths()
            } label: {
                Label("Stage", systemImage: "plus.square")
            }
            Button {
                selectOnly(file)
                model.unstageSelectedWorktreePaths()
            } label: {
                Label("Unstage", systemImage: "minus.square")
            }
            Divider()
            Button {
                gitBudCopyToPasteboard(file.path)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                selectOnly(file)
                model.discardSelectedWorktreePaths()
            } label: {
                Label("Discard Changes", systemImage: "arrow.uturn.backward")
            }
        }
        .disabled(model.isUpdatingWorktree || model.hasConflicts)
    }

    private var allSelected: Bool {
        !model.worktreeFiles.isEmpty &&
        model.selectedWorktreePaths.count == model.worktreeFiles.count
    }

    private func toggleAll() {
        if allSelected {
            model.selectedWorktreePaths.removeAll()
        } else {
            model.selectedWorktreePaths = Set(model.worktreeFiles.map(\.path))
        }
    }

    private func selectOnly(_ file: GitWorktreeFile) {
        model.selectedWorktreePaths = [file.path]
    }

    private func statusColor(_ file: GitWorktreeFile) -> Color {
        if file.displayStatus.contains("?") || file.displayStatus.contains("A") { return .green }
        if file.displayStatus.contains("D") { return .red }
        if file.displayStatus.contains("R") { return .purple }
        return .orange
    }
}
