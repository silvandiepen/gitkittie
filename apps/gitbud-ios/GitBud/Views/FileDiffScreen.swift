import GitKittieKit
import GitPontCore
import SwiftUI

/// How a file's diff is read.
enum DiffMode: String, CaseIterable, Identifiable {
    case unified, sideBySide, fullFile
    var id: String { rawValue }

    var title: String {
        switch self {
        case .unified: return "Unified"
        case .sideBySide: return "Side by Side"
        case .fullFile: return "Full File"
        }
    }
}

/// One file of a commit. Tap a changed line to choose it, or a hunk's header to choose all
/// of it; the choice is kept per commit, across files and views.
struct FileDiffScreen: View {
    let file: GitCommitFileChange
    let diff: GitFileDiff?
    let commit: GitCommitDetail
    /// Every file of the commit: the choice spans all of them.
    let allDiffs: [GitFileDiff]
    @Binding var selection: GitChangeSelection
    let initialMode: DiffMode

    @State private var compose: ComposeSheet.Intent?
    private var commitSHA: String { commit.summary.sha }

    @Environment(AppModel.self) private var model
    @State private var mode: DiffMode = .unified
    @State private var fullFile: GitFileDiff?
    @State private var fullFileProblem: String?

    var body: some View {
        Group {
            if let diff {
                switch mode {
                case .unified: lines(diff, layout: .unified)
                case .sideBySide: lines(diff, layout: .sideBySide)
                case .fullFile:
                    if let fullFile {
                        lines(fullFile, layout: .unified, mappedFrom: diff)
                    } else if let fullFileProblem {
                        ContentUnavailableView("Full file not available", systemImage: "doc", description: Text(fullFileProblem))
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                ContentUnavailableView(
                    file.isBinary ? "A binary file" : "No text changes",
                    systemImage: "doc",
                    description: Text(file.isBinary ? "Its changes can't be shown as lines." : "Only the file's name or mode changed, or the host left a large patch out."))
            }
        }
        .background(Theme.window)
        .navigationTitle((file.path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            if diff != nil {
                Picker("View", selection: $mode) {
                    ForEach(DiffMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.window)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ChosenLinesBar(selection: $selection, diffs: allDiffs) { compose = $0 }
        }
        .animation(.snappy(duration: 0.2), value: selection.isEmpty)
        .sheet(item: $compose) { intent in
            ComposeSheet(intent: intent, commit: commit, diffs: allDiffs, selection: selection) {
                selection.clear()
            }
        }
        .onAppear { mode = initialMode }
        .task(id: mode) { if mode == .fullFile, fullFile == nil { await loadFullFile() } }
    }

    private func loadFullFile() async {
        guard let diff else { return }
        if file.status == .removed {
            fullFileProblem = "This commit removed the file."
            return
        }
        do {
            guard let text = try await model.text(of: file.path, at: commitSHA) else {
                fullFileProblem = "The host did not return the file."
                return
            }
            if let hunk = GitDiffLayout.fullFile(newText: text, hunks: diff.hunks, path: diff.path) {
                fullFile = GitFileDiff(path: diff.path, oldPath: diff.oldPath, hunks: [hunk], isNewFile: diff.isNewFile, isDeletedFile: diff.isDeletedFile)
            } else {
                fullFileProblem = "The file's text and its changes don't line up."
            }
        } catch {
            fullFileProblem = error.localizedDescription
        }
    }

    // MARK: - Lines

    private enum Layout { case unified, sideBySide }

    /// `shown` is what is drawn; choices are kept in terms of `mappedFrom` (the commit's own
    /// hunks) when given, so Full File and the other views share one selection.
    private func lines(_ shown: GitFileDiff, layout: Layout, mappedFrom base: GitFileDiff? = nil) -> some View {
        let shownSelection = base.map { selection.remapped(from: [$0], to: [shown]) } ?? selection
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(shown.hunks) { hunk in
                    Section {
                        if layout == .sideBySide {
                            ForEach(GitDiffLayout.rows(of: hunk)) { row in
                                HStack(spacing: 0) {
                                    cell(row.left, number: row.left?.oldNumber, hunk: hunk, chosen: shownSelection, shown: shown, base: base)
                                    Rectangle().fill(Theme.stroke).frame(width: 1)
                                    cell(row.right, number: row.right?.newNumber, hunk: hunk, chosen: shownSelection, shown: shown, base: base)
                                }
                            }
                        } else {
                            ForEach(GitDiffLayout.lines(of: hunk)) { line in
                                row(line, hunk: hunk, chosen: shownSelection, shown: shown, base: base)
                            }
                        }
                    } header: {
                        hunkHeader(hunk, chosen: shownSelection, shown: shown, base: base)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private func hunkHeader(_ hunk: GitHunk, chosen: GitChangeSelection, shown: GitFileDiff, base: GitFileDiff?) -> some View {
        let all = chosen.containsAll(of: hunk)
        return HStack(spacing: 10) {
            if !GitPatchBuilder.changeIndexes(of: hunk).isEmpty {
                Button {
                    update(shown: shown, base: base) { $0.toggle(hunk) }
                } label: {
                    Label(all ? "Clear" : "Choose All", systemImage: all ? "checkmark.circle.fill" : "circle")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
            }
            Text(hunk.header)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.panel)
    }

    private func row(_ line: GitDiffLine, hunk: GitHunk, chosen: GitChangeSelection, shown: GitFileDiff, base: GitFileDiff?) -> some View {
        let isChosen = line.isChange && chosen.contains(hunk, line: line.index)
        return HStack(alignment: .top, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            mark(line, chosen: isChosen)
            Text(line.text.isEmpty ? " " : line.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 10)
        }
        .padding(.vertical, 2)
        .background(fill(line.kind, chosen: isChosen))
        .contentShape(Rectangle())
        .onTapGesture { if line.isChange { update(shown: shown, base: base) { $0.toggle(hunk, line: line.index) } } }
        .contextMenu { Button("Copy Line") { UIPasteboard.general.string = line.text } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(line.isChange ? .isButton : [])
        .accessibilityValue(isChosen ? "Chosen" : "")
    }

    @ViewBuilder
    private func cell(_ line: GitDiffLine?, number value: Int?, hunk: GitHunk, chosen: GitChangeSelection, shown: GitFileDiff, base: GitFileDiff?) -> some View {
        if let line {
            let isChosen = line.isChange && chosen.contains(hunk, line: line.index)
            HStack(alignment: .top, spacing: 0) {
                number(value)
                mark(line, chosen: isChosen)
                Text(line.text.isEmpty ? " " : line.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 6)
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(fill(line.kind, chosen: isChosen))
            .contentShape(Rectangle())
            .onTapGesture { if line.isChange { update(shown: shown, base: base) { $0.toggle(hunk, line: line.index) } } }
        } else {
            Color.primary.opacity(0.03).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: 32, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private func mark(_ line: GitDiffLine, chosen: Bool) -> some View {
        Group {
            if chosen {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.accentColor)
            } else {
                Text(line.kind == .addition ? "+" : line.kind == .removal ? "−" : " ")
                    .foregroundStyle(line.kind == .addition ? Color.green : line.kind == .removal ? Color.red : Color.secondary)
            }
        }
        .frame(width: 16)
    }

    private func fill(_ kind: GitDiffLine.Kind, chosen: Bool) -> Color {
        if chosen { return Color.accentColor.opacity(0.26) }
        switch kind {
        case .addition: return Color.green.opacity(0.13)
        case .removal: return Color.red.opacity(0.13)
        case .context: return .clear
        }
    }

    /// Changes the choice in the reading shown, and keeps it in the commit's own terms.
    private func update(shown: GitFileDiff, base: GitFileDiff?, _ change: (inout GitChangeSelection) -> Void) {
        guard let base else {
            change(&selection)
            return
        }
        var inShown = selection.remapped(from: [base], to: [shown])
        change(&inShown)
        let back = inShown.remapped(from: [shown], to: [base])
        for hunk in base.hunks { selection.lines[hunk.id] = back.lines[hunk.id] ?? [] }
    }
}
