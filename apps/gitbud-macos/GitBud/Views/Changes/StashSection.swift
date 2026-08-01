import GitBudCore
import GitKittieKit
import SwiftUI

/// Stashes, collapsed until you have one. Actions hang off each stash rather than a
/// row of five icon buttons.
struct StashSection: View {
    @Environment(AppModel.self) private var model
    @State private var pending: PendingStashBranch?

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Stashes", systemImage: "archivebox")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(GitBudTheme.secondaryText)
                Spacer()
                if model.isRunningStashOperation {
                    ProgressView().controlSize(.small)
                }
                Button {
                    model.saveStash()
                } label: {
                    Label("Stash All", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .disabled(model.worktreeFiles.isEmpty || model.hasConflicts || model.isRunningStashOperation)

                if !model.selectedWorktreePaths.isEmpty {
                    Button {
                        model.saveSelectedWorktreePathsToStash()
                    } label: {
                        Text("Stash Selected")
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .disabled(model.hasConflicts || model.isRunningStashOperation)
                }
            }

            if model.stashes.isEmpty {
                Text("No stashes.")
                    .font(.caption)
                    .foregroundStyle(GitBudTheme.secondaryText)
            } else {
                ForEach(model.stashes) { stash in
                    stashRow(stash)
                }
            }
        }
        .padding(16)
        .sheet(item: $pending) { request in
            StashBranchSheet(stashID: request.id) { pending = nil }
        }
    }

    private func stashRow(_ stash: GitStashEntry) -> some View {
        HStack(spacing: 8) {
            Text(stash.id)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(GitBudTheme.secondaryText)
            Text(stash.message)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .gitBudPanelRow(isSelected: model.selectedStashID == stash.id, cornerRadius: 8, baseOpacity: 0.045)
        .onTapGesture { model.selectedStashID = stash.id }
        .contextMenu {
            Button {
                model.selectedStashID = stash.id
                model.applySelectedStash()
            } label: {
                Label("Apply", systemImage: "tray.and.arrow.up")
            }
            .disabled(!model.worktreeFiles.isEmpty)
            Button {
                model.selectedStashID = stash.id
                model.popSelectedStash()
            } label: {
                Label("Pop", systemImage: "tray.full")
            }
            .disabled(!model.worktreeFiles.isEmpty)
            Button {
                model.selectedStashID = stash.id
                pending = PendingStashBranch(id: stash.id)
            } label: {
                Label("Create Branch…", systemImage: "arrow.triangle.branch")
            }
            .disabled(!model.worktreeFiles.isEmpty)
            Divider()
            Button(role: .destructive) {
                model.selectedStashID = stash.id
                model.dropSelectedStash()
            } label: {
                Label("Drop", systemImage: "trash")
            }
        }
        .disabled(model.hasConflicts || model.isRunningStashOperation)
    }

    private struct PendingStashBranch: Identifiable {
        let id: String
    }
}

private struct StashBranchSheet: View {
    @Environment(AppModel.self) private var model
    let stashID: String
    let onDismiss: () -> Void

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create a branch from \(stashID)")
                .font(.headline.weight(.semibold))
            TextField("feature/from-stash", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Branch", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(GitBudTheme.panel)
        .foregroundStyle(GitBudTheme.primaryText)
    }

    private func create() {
        model.selectedStashID = stashID
        model.newBranchName = name
        model.createBranchFromSelectedStash()
        onDismiss()
    }
}
