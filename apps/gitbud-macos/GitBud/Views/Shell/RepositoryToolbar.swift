import GitBudCore
import GitKit
import SwiftUI

/// Repository-wide verbs — the ones that act on the repo rather than on a selected item.
/// Fetch, pull, and push earn permanent space because they are what you reach for most.
struct RepositoryToolbar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.branchSummary?.currentBranch ?? "Detached HEAD")
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Text(upstreamLine)
                    .font(.caption)
                    .foregroundStyle(GitBudTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            if model.isLoading || model.isSyncingRemote || model.isRewriting {
                ProgressView().controlSize(.small)
            }

            Button {
                model.fetchRemote()
            } label: {
                Label("Fetch", systemImage: "arrow.clockwise")
            }
            .help("Fetch from the remote")
            .disabled(busy)

            Button {
                model.pullCurrentBranchWithRebase()
            } label: {
                Label("Pull", systemImage: "arrow.down.circle")
            }
            .help("Pull with rebase")
            .disabled(busy || !model.worktreeFiles.isEmpty)

            Button {
                model.pushCurrentBranch()
            } label: {
                Label("Push", systemImage: "arrow.up.circle")
            }
            .help("Push the current branch")
            .disabled(busy)

            Divider().frame(height: 20)

            Button {
                model.openRepositoryPanel()
            } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open another repository")

            Button {
                Task { await model.reload() }
            } label: {
                Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Reload from disk")
            .disabled(model.isLoading)
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(.black.opacity(0.18))
    }

    private var upstreamLine: String {
        guard let summary = model.branchSummary else { return model.statusMessage }
        guard let upstream = summary.upstream else { return "No upstream · \(model.statusMessage)" }
        return "\(upstream) · ahead \(summary.ahead), behind \(summary.behind)"
    }

    private var busy: Bool {
        model.isSyncingRemote || model.isRewriting || model.hasConflicts
    }
}
