import GitKittieKit
import GitPontCore
import SwiftUI

/// One commit: its whole message, who and when, and every file it changed. Changed lines
/// chosen in any of its files can become a pull request that undoes them or brings them to
/// another branch.
struct CommitScreen: View {
    let sha: String

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var detail: GitCommitDetail?
    @State private var loadError: String?
    @State private var selection = GitChangeSelection()
    @State private var path = NavigationPath()
    @State private var compose: ComposeSheet.Intent?
    @State private var didApplyHooks = false

    /// The commit's files as diffs the shared layout and patch builder understand.
    private var diffs: [GitFileDiff] {
        (detail?.files ?? []).compactMap { file in
            guard let patch = file.patch else { return nil }
            return GitFileDiff(
                path: file.path, oldPath: file.previousPath, hunksText: patch,
                isNewFile: file.status == .added, isDeletedFile: file.status == .removed)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            screen
        }
    }

    private var screen: some View {
        Group {
            if let detail {
                content(detail)
            } else if let loadError {
                ContentUnavailableView("This commit could not be read", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.window)
        .navigationTitle(detail?.summary.shortSHA ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $compose) { intent in
            if let detail {
                ComposeSheet(intent: intent, commit: detail, diffs: diffs, selection: selection) {
                    selection.clear()
                }
            }
        }
    }

    private func load() async {
        do {
            detail = try await model.detail(of: sha)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func content(_ detail: GitCommitDetail) -> some View {
        List {
            Section { header(detail) }
                .listRowBackground(Theme.panel)

            Section {
                ForEach(detail.files) { file in
                    NavigationLink(value: file.path) { fileRow(file) }
                }
                if detail.filesTruncated {
                    Text("The host sent part of the files; open the commit on the web for the rest.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("\(detail.files.count) file\(detail.files.count == 1 ? "" : "s")")
            }
            .listRowBackground(Theme.panel)
        }
        .scrollContentBackground(.hidden)
        .navigationDestination(for: String.self) { path in
            if let file = detail.files.first(where: { $0.path == path }) {
                FileDiffScreen(
                    file: file,
                    diff: diffs.first { $0.path == path },
                    commit: detail,
                    allDiffs: diffs,
                    selection: $selection,
                    initialMode: CaptureHooks.diffMode ?? .unified)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ChosenLinesBar(selection: $selection, diffs: diffs) { compose = $0 }
        }
        .onAppear {
            // GITBUD_FILE: open that file straight away, once.
            if !didApplyHooks, let file = CaptureHooks.file, detail.files.contains(where: { $0.path == file }) {
                didApplyHooks = true
                path.append(file)
            }
        }
    }

    private func header(_ detail: GitCommitDetail) -> some View {
        let summary = detail.summary
        let added = detail.files.reduce(0) { $0 + $1.additions }
        let removed = detail.files.reduce(0) { $0 + $1.deletions }
        return VStack(alignment: .leading, spacing: 10) {
            Text(summary.subject)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            if !summary.body.isEmpty {
                Text(summary.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 12) {
                Label(summary.authorName, systemImage: "person.circle")
                if let date = summary.authoredAt {
                    Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = summary.sha
                    model.statusMessage = "Copied \(summary.shortSHA)."
                } label: {
                    Label(summary.shortSHA, systemImage: "number").monospaced()
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy commit id")
                if summary.isMerge {
                    Text("Merge of \(summary.parentSHAs.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.16), in: Capsule())
                }
                Spacer()
                Text("+\(added)").foregroundStyle(.green)
                Text("−\(removed)").foregroundStyle(.red)
                if let url = summary.webURL {
                    Button { openURL(url) } label: { Image(systemName: "safari") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Open on the web")
                }
            }
            .font(.callout.monospacedDigit())
        }
        .padding(.vertical, 6)
    }

    private func fileRow(_ file: GitCommitFileChange) -> some View {
        let name = (file.path as NSString).lastPathComponent
        let folder = (file.path as NSString).deletingLastPathComponent
        let chosen = diffs.first { $0.path == file.path }.map { selection.count(in: [$0]) } ?? 0
        return HStack(spacing: 10) {
            Text(statusLetter(file.status))
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(statusColor(file.status))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                if !folder.isEmpty {
                    Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            if chosen > 0 {
                Text("\(chosen)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
                    .accessibilityLabel("\(chosen) lines chosen")
            }
            if file.isBinary {
                Text("Binary").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("+\(file.additions)").foregroundStyle(.green)
                    Text("−\(file.deletions)").foregroundStyle(.red)
                }
                .font(.caption2.monospacedDigit())
            }
        }
    }

    private func statusLetter(_ status: GitCommitFileStatus) -> String {
        switch status {
        case .added: return "A"
        case .removed: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .modified, .unknown: return "M"
        }
    }

    private func statusColor(_ status: GitCommitFileStatus) -> Color {
        switch status {
        case .added: return .green
        case .removed: return .red
        case .renamed, .copied: return .purple
        case .modified, .unknown: return .orange
        }
    }
}

/// Shown once lines are chosen, on the commit and on each of its files: how many, and the
/// two things to do with them.
struct ChosenLinesBar: View {
    @Binding var selection: GitChangeSelection
    let diffs: [GitFileDiff]
    var onCompose: (ComposeSheet.Intent) -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        if !selection.isEmpty {
            let chosen = selection.count(in: diffs)
            let name = model.connection?.changeRequestName ?? "pull request"
            VStack(spacing: 10) {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    Text("\(chosen) changed line\(chosen == 1 ? "" : "s") chosen").font(.callout.weight(.medium))
                    Spacer()
                    Button("Clear") { selection.clear() }
                }
                HStack(spacing: 10) {
                    Button {
                        onCompose(.undo)
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("undoChosen")
                    .accessibilityHint("Opens a \(name) that takes these lines back out")
                    Button {
                        onCompose(.pick)
                    } label: {
                        Label("Bring to a branch", systemImage: "arrow.triangle.branch")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .disabled(!model.canWrite)
                if !model.canWrite {
                    Text("You can read this repository but not push to it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(Theme.panel)
            .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
