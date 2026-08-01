import GitBudCore
import GitKittieKit
import SwiftUI

/// The files a commit touched. Right-click a file for what you can do to it; tick one to
/// stage it for a split. File history and blame sit below, collapsed until asked for.
struct FileList: View {
    @Environment(AppModel.self) private var model
    @State private var pending: GitBudAction?
    @State private var isShowingHistory = false
    @State private var isShowingBlame = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Files")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(GitBudTheme.secondaryText)
                Spacer()
                if !model.selectedSplitPaths.isEmpty || !model.selectedSplitHunkIDs.isEmpty {
                    Text("\(model.selectedSplitPaths.count + model.selectedSplitHunkIDs.count) to split")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.changedFiles) { file in
                        fileRow(file)
                    }
                    if model.changedFiles.isEmpty {
                        Text("No files in this commit.")
                            .font(.caption)
                            .foregroundStyle(GitBudTheme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
                .padding(.horizontal, 10)
            }

            Divider().overlay(.white.opacity(0.08))

            DisclosureGroup(isExpanded: $isShowingHistory) {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(model.fileHistory) { commit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(commit.message)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(2)
                            Text(String(commit.id.prefix(8)))
                                .font(.caption2.monospaced())
                                .foregroundStyle(GitBudTheme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .gitBudPanelRow(cornerRadius: 7, baseOpacity: 0.04)
                    }
                }
                .frame(maxHeight: 160)
            } label: {
                Text("File History")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(GitBudTheme.secondaryText)
            }
            .disabled(model.selectedFilePath == nil)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            DisclosureGroup(isExpanded: $isShowingBlame) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.fileBlame) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(line.lineNumber)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(GitBudTheme.secondaryText)
                                    .frame(width: 28, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Text(line.shortCommitID)
                                            .font(.caption2.monospaced().weight(.semibold))
                                        Text(line.author)
                                            .font(.caption2)
                                            .foregroundStyle(GitBudTheme.secondaryText)
                                            .lineLimit(1)
                                    }
                                    Text(line.content.isEmpty ? " " : line.content)
                                        .font(.caption2.monospaced())
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(5)
                            .gitBudPanelRow(cornerRadius: 7, baseOpacity: 0.04)
                        }
                    }
                }
                .frame(maxHeight: 180)
            } label: {
                Text("Blame")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(GitBudTheme.secondaryText)
            }
            .disabled(model.selectedFilePath == nil)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .actionSheet(pending: $pending)
    }

    private func fileRow(_ file: GitChangedFile) -> some View {
        let isSplitting = model.selectedSplitPaths.contains(file.path)

        return HStack(spacing: 8) {
            Button {
                model.toggleSplitPath(file)
            } label: {
                Image(systemName: isSplitting ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSplitting ? Color.accentColor : GitBudTheme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Include this file when splitting the commit")

            Text(file.status)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(statusColor(file.status))
                .frame(width: 24)

            Text(file.path)
                .font(.caption)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(8)
        .contentShape(Rectangle())
        .gitBudPanelRow(
            isSelected: model.selectedFilePath == file.path,
            isMarked: isSplitting,
            markedColor: .orange,
            cornerRadius: 8,
            baseOpacity: 0.045
        )
        .onTapGesture { model.selectFile(file) }
        .contextMenu {
            ActionMenuItems(actions: GitBudActions.file(file, model: model), pending: $pending)
        }
    }

    private func statusColor(_ status: String) -> Color {
        if status.hasPrefix("A") { return .green }
        if status.hasPrefix("D") { return .red }
        if status.hasPrefix("R") { return .purple }
        return .orange
    }
}
