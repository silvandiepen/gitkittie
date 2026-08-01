import GitBudCore
import GitKittieKit
import SwiftUI

/// A list of branches, most recently updated first. That is all this surface is.
/// `GitHistory.branches` already sorts by committer date, so the order is git's own.
struct BranchesView: View {
    @Environment(AppModel.self) private var model
    @State private var pending: GitBudAction?
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.08))
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(locals) { branch in
                        BranchRow(branch: branch, pending: $pending)
                    }

                    if !remotes.isEmpty {
                        sectionLabel("Remote")
                        ForEach(remotes) { branch in
                            BranchRow(branch: branch, pending: $pending)
                        }
                    }

                    sectionLabel("Tags")
                    TagSection(pending: $pending)
                }
                .padding(12)
            }
        }
        .actionSheet(pending: $pending)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Branches")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Most recently updated first")
                    .font(.caption)
                    .foregroundStyle(GitBudTheme.secondaryText)
            }
            Spacer()
            if model.isChangingBranch || model.isRunningBranchOperation {
                ProgressView().controlSize(.small)
            }
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
        }
        .padding(16)
    }

    private func sectionLabel(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(GitBudTheme.secondaryText)
            Spacer()
        }
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    private var matching: [GitBranch] {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return model.branches }
        return model.branches.filter { $0.shortName.localizedCaseInsensitiveContains(trimmed) }
    }

    private var locals: [GitBranch] { matching.filter { $0.kind == .local } }
    private var remotes: [GitBranch] { matching.filter { $0.kind == .remote } }
}
