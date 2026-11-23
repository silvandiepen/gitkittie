import AppKit
import GitBudCore
import GitKittieKit
import SwiftUI

/// How the commit window shows a diff.
enum CommitDiffMode: String, CaseIterable, Identifiable {
    case unified, sideBySide, fullFile
    var id: String { rawValue }

    var title: String {
        switch self {
        case .unified: return "Unified"
        case .sideBySide: return "Side by Side"
        case .fullFile: return "Full File"
        }
    }

    var icon: String {
        switch self {
        case .unified: return "text.alignleft"
        case .sideBySide: return "rectangle.split.2x1"
        case .fullFile: return "doc.text"
        }
    }
}

/// A commit in a window of its own: the whole message, who and when, every file with its
/// size of change, and the diff read three ways. Lines can be chosen and either applied to
/// the working copy or undone there — ordinary changes to review, history untouched.
struct CommitWindow: View {
    static let windowID = "commit"

    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    let commitID: String

    @State private var document: GitBudCommitDocument?
    @State private var loadError: String?
    @State private var mode: CommitDiffMode = .unified
    @State private var ignoreWhitespace = false
    @State private var selectedPath: String?
    @State private var selection = GitChangeSelection()
    @State private var isApplying = false
    @State private var pending: GitBudAction?
    @State private var suggestions: [SuggestedCommit] = []
    @State private var isSuggesting = false
    @State private var isShowingSuggestions = false
    @State private var didApplyCaptureHooks = false

    private var options: GitDiffOptions {
        GitDiffOptions(contextLines: mode == .fullFile ? nil : 3, ignoreWhitespace: ignoreWhitespace)
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.repositoryURL == nil {
                EmptyPanel(title: "No repository open", message: "Open the repository this commit belongs to, and it shows here.")
            } else if let document {
                header(document)
                Divider().overlay(GitBudTheme.stroke)
                HSplitView {
                    fileList(document)
                        .frame(minWidth: 200, idealWidth: 250, maxWidth: 320)
                    diffColumn(document)
                        .frame(minWidth: 480)
                }
            } else if let loadError {
                EmptyPanel(title: "This commit could not be read", message: loadError)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(GitBudTheme.background)
        .navigationTitle(document?.commit?.subject ?? "Commit")
        .navigationSubtitle(document?.commit.map { "\($0.shortID) · \(model.repositoryName)" } ?? "")
        // Reloads with the reading options, and when the repository is opened (a window that
        // macOS restores at launch can appear before the repository has loaded).
        .task(id: LoadKey(options: options, repository: model.repositoryURL, commits: model.commits.count)) { await load() }
        // Restored at launch on its own, a commit window has no repository to read: bring
        // the main window back, which is where a repository is opened.
        .onAppear {
            if model.repositoryURL == nil { openWindow(id: GitBudApp.mainWindowID) }
        }
        .actionSheet(pending: $pending)
    }

    // MARK: - Loading

    private struct LoadKey: Equatable {
        let options: GitDiffOptions
        let repository: URL?
        let commits: Int
    }

    private func load() async {
        guard model.repositoryURL != nil else { return }
        let previous = document?.diffs ?? []
        do {
            let loaded = try await model.commitDocument(commitID, options: options)
            // The same chosen lines in the new reading (more context, or whitespace hidden).
            if !previous.isEmpty { selection = selection.remapped(from: previous, to: loaded.diffs) }
            document = loaded
            loadError = nil
            if selectedPath == nil || !loaded.files.contains(where: { $0.path == selectedPath }) {
                selectedPath = loaded.files.first?.path
            }
            applyCaptureHooks(loaded)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Launch hooks for screenshots, applied once to the first window that loads, like iOS:
    /// `GITBUD_FILE=<path>`, `GITBUD_DIFF_MODE=unified|sideBySide|fullFile`,
    /// `GITBUD_CHOOSE=<text>` (choose the changed lines containing it), `GITBUD_SUGGEST=1`.
    /// No-ops when unset.
    private func applyCaptureHooks(_ loaded: GitBudCommitDocument) {
        guard !didApplyCaptureHooks else { return }
        didApplyCaptureHooks = true
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["GITBUD_FILE"], loaded.files.contains(where: { $0.path == path }) { selectedPath = path }
        if let wanted = environment["GITBUD_DIFF_MODE"].flatMap(CommitDiffMode.init(rawValue:)), wanted != mode { mode = wanted }
        if let text = environment["GITBUD_CHOOSE"], !text.isEmpty {
            for hunk in loaded.diffs.flatMap(\.hunks) {
                for (index, line) in hunk.lines.enumerated() where line.contains(text) { selection.toggle(hunk, line: index) }
            }
        }
        if environment["GITBUD_SUGGEST"] == "1", model.onDeviceMagicUnavailableReason == nil { suggestSplit() }
    }

    // MARK: - Header

    private func header(_ document: GitBudCommitDocument) -> some View {
        let commit = document.commit
        let stats = document.stats.values.reduce((added: 0, removed: 0)) { ($0.added + $1.added, $0.removed + $1.removed) }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(commit?.subject ?? commitID)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let body = commit?.body.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                        Text(body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 760, alignment: .leading)
                    }
                }
                Spacer(minLength: 12)
                headerActions(commit)
            }

            HStack(spacing: 14) {
                if let commit {
                    Label(commit.author, systemImage: "person.circle")
                    Label(commit.authorDate.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(commit.id, forType: .string)
                        model.statusMessage = "Copied \(commit.shortID)."
                    } label: {
                        Label(commit.shortID, systemImage: "number").monospaced()
                    }
                    .buttonStyle(.plain)
                    .help("Copy the full commit id")
                    if commit.parentIDs.count > 1 {
                        StatusPill(title: "Merge of \(commit.parentIDs.count)", color: .purple)
                    }
                    ForEach(commit.decorations.prefix(4), id: \.self) { ref in
                        StatusPill(title: ref, color: .accentColor)
                    }
                }
                Spacer()
                Text("\(document.files.count) file\(document.files.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Text("+\(stats.added)").foregroundStyle(.green).monospacedDigit()
                Text("−\(stats.removed)").foregroundStyle(.red).monospacedDigit()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(GitBudTheme.panel)
    }

    private func headerActions(_ commit: GitCommitNode?) -> some View {
        HStack(spacing: 8) {
            if model.onDeviceMagicUnavailableReason == nil {
                Button {
                    suggestSplit()
                } label: {
                    if isSuggesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Suggest a Split", systemImage: "sparkles")
                    }
                }
                .help("Apple Intelligence on this Mac suggests how this commit splits into smaller ones")
                .disabled(isSuggesting || (document?.diffs.flatMap(\.hunks).count ?? 0) < 2)
                .popover(isPresented: $isShowingSuggestions, arrowEdge: .bottom) { suggestionList }
            }
            if let commit {
                Menu {
                    ActionMenuItems(actions: GitBudActions.commit(commit, model: model), pending: $pending)
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    // MARK: - Split suggestions (on device)

    private func suggestSplit() {
        isSuggesting = true
        Task {
            defer { isSuggesting = false }
            do {
                suggestions = try await model.suggestSplit(of: commitID)
                isShowingSuggestions = true
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(suggestions.isEmpty ? "Nothing to split" : "Suggested commits")
                .font(.headline)
            Text(suggestions.isEmpty
                 ? "Apple Intelligence reads this commit as one change."
                 : "Drafted on this Mac. Use one to tick its changes and fill in its message; you split it off in History.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(suggestions) { suggestion in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(suggestion.id)")
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(suggestion.message).font(.callout.weight(.medium))
                        Text(files(of: suggestion))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Button("Use") {
                        isShowingSuggestions = false
                        Task {
                            await model.prepareSplit(suggestion, of: commitID)
                            // Back to the main window, where the split waits.
                            openWindow(id: GitBudApp.mainWindowID)
                            dismissWindow()
                        }
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .gitBudPanelRow(cornerRadius: 8, baseOpacity: 0.04)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func files(of suggestion: SuggestedCommit) -> String {
        let hunks = Set(suggestion.hunkIDs)
        let paths = (document?.diffs ?? []).filter { $0.hunks.contains { hunks.contains($0.id) } }.map(\.path)
        return "\(suggestion.hunkIDs.count) change\(suggestion.hunkIDs.count == 1 ? "" : "s") in " + paths.joined(separator: ", ")
    }

    // MARK: - Files

    private func fileList(_ document: GitBudCommitDocument) -> some View {
        let stats = document.stats
        return List(selection: $selectedPath) {
            Section("Files") {
                ForEach(document.files) { file in
                    fileRow(file, stats: stats[file.path], diff: document.diffs.first { $0.path == file.path })
                        .tag(file.path)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(GitBudTheme.sidebar)
    }

    private func fileRow(_ file: GitChangedFile, stats: (added: Int, removed: Int)?, diff: GitFileDiff?) -> some View {
        let name = (file.path as NSString).lastPathComponent
        let folder = (file.path as NSString).deletingLastPathComponent
        let chosen = diff.map { selection.count(in: [$0]) } ?? 0

        return HStack(spacing: 8) {
            Text(String(file.status.prefix(1)))
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(statusColor(file.status))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout).lineLimit(1)
                if !folder.isEmpty {
                    Text(folder).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if chosen > 0 {
                CountBadge(count: chosen, color: .accentColor).help("\(chosen) changed line\(chosen == 1 ? "" : "s") chosen")
            }
            if let stats {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("+\(stats.added)").foregroundStyle(.green)
                    Text("−\(stats.removed)").foregroundStyle(.red)
                }
                .font(.caption2.monospacedDigit())
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let diff {
                Button(chosenAll(diff) ? "Clear Chosen Lines" : "Choose Every Change") { selection.toggle(diff) }
            }
        }
    }

    private func chosenAll(_ diff: GitFileDiff) -> Bool {
        !diff.hunks.isEmpty && diff.hunks.allSatisfy { selection.containsAll(of: $0) }
    }

    private func statusColor(_ status: String) -> Color {
        if status.hasPrefix("A") { return .green }
        if status.hasPrefix("D") { return .red }
        if status.hasPrefix("R") { return .purple }
        return .orange
    }

    // MARK: - Diff

    private func diffColumn(_ document: GitBudCommitDocument) -> some View {
        VStack(spacing: 0) {
            diffToolbar
            Divider().overlay(GitBudTheme.stroke)
            if let path = selectedPath, let diff = document.diffs.first(where: { $0.path == path }) {
                CommitDiffView(diff: diff, mode: mode, selection: $selection)
            } else if let path = selectedPath, document.files.contains(where: { $0.path == path }) {
                EmptyPanel(title: "No text changes", message: "A binary file, or a change only to the file's mode or name.")
            } else {
                EmptyPanel(title: "Select a file", message: "Choose a file on the left to read its changes.")
            }
            let chosen = selection.count(in: document.diffs)
            if chosen > 0 {
                Divider().overlay(GitBudTheme.stroke)
                selectionBar(chosen: chosen, document)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: selection.isEmpty)
    }

    /// How to read the diff. What to do with chosen lines sits in the bar at the bottom.
    private var diffToolbar: some View {
        HStack(spacing: 14) {
            Picker("View", selection: $mode) {
                ForEach(CommitDiffMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .labelsHidden()
            .fixedSize()

            Toggle("Ignore Whitespace", isOn: $ignoreWhitespace)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Hide changes that only add or remove spaces")

            Spacer(minLength: 8)

            if selection.isEmpty {
                Text("Click changed lines to choose them")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(GitBudTheme.panel)
    }

    /// Shown once lines are chosen: how many, and the two things to do with them.
    private func selectionBar(chosen: Int, _ document: GitBudCommitDocument) -> some View {
        let canApply = !ignoreWhitespace && !isApplying
        return HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text("\(chosen) changed line\(chosen == 1 ? "" : "s") chosen")
                .font(.callout.weight(.medium))
            Button("Clear") { selection.clear() }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            Spacer(minLength: 8)
            if isApplying { ProgressView().controlSize(.small) }
            Button {
                apply(reverse: true, document)
            } label: {
                Label("Undo in Working Copy", systemImage: "arrow.uturn.backward")
            }
            .help(applyHelp(canApply, verb: "Take these changes back out of your files"))
            .disabled(!canApply)
            Button {
                apply(reverse: false, document)
            } label: {
                Label("Apply to Working Copy", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .help(applyHelp(canApply, verb: "Put these changes into your files, as this commit made them"))
            .disabled(!canApply)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(GitBudTheme.panel)
    }

    private func applyHelp(_ canApply: Bool, verb: String) -> String {
        if ignoreWhitespace { return "Turn off Ignore Whitespace to pick or undo lines" }
        if isApplying { return "Working…" }
        return verb + ". History is not changed; review the result in Changes."
    }

    private func apply(reverse: Bool, _ document: GitBudCommitDocument) {
        isApplying = true
        Task {
            defer { isApplying = false }
            if await model.applyCommitChanges(of: commitID, document.diffs, selection: selection, reverse: reverse) {
                selection.clear()
            }
        }
    }
}
