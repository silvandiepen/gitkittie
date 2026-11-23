import AppKit
import GitBudCore
import GitKittieKit
import SwiftUI

/// One file's diff in the commit window: unified (also used for Full File, which is the same
/// layout with every line of the file) or side by side. Changed lines can be chosen.
struct CommitDiffView: View {
    let diff: GitFileDiff
    let mode: CommitDiffMode
    @Binding var selection: GitChangeSelection
    /// The last line clicked, so a ⇧-click can choose everything between.
    @State private var anchor: GitDiffLine?

    private static let gutter: CGFloat = 44

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(diff.hunks) { hunk in
                    Section {
                        if mode == .sideBySide {
                            ForEach(GitDiffLayout.rows(of: hunk)) { row in
                                sideBySideRow(row, hunk: hunk)
                            }
                        } else {
                            ForEach(GitDiffLayout.lines(of: hunk)) { line in
                                unifiedRow(line, hunk: hunk)
                            }
                        }
                    } header: {
                        hunkHeader(hunk)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .background(GitBudTheme.background)
        .font(.system(size: 12, design: .monospaced))
    }

    // MARK: - Rows

    private func hunkHeader(_ hunk: GitHunk) -> some View {
        let all = selection.containsAll(of: hunk)
        let hasChanges = !GitPatchBuilder.changeIndexes(of: hunk).isEmpty
        return HStack(spacing: 10) {
            if hasChanges {
                Button {
                    selection.toggle(hunk)
                } label: {
                    Label(all ? "Clear Hunk" : "Choose Hunk", systemImage: all ? "checkmark.circle.fill" : "circle")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(all ? Color.accentColor : .secondary)
                .help(all ? "Clear every chosen line in this hunk" : "Choose every changed line in this hunk")
            }
            Text(hunk.header)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(GitBudTheme.panel)
    }

    private func unifiedRow(_ line: GitDiffLine, hunk: GitHunk) -> some View {
        let chosen = line.isChange && selection.contains(hunk, line: line.index)
        return HStack(alignment: .top, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            mark(line, chosen: chosen)
            Text(line.text.isEmpty ? " " : line.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 12)
        }
        .padding(.vertical, 1)
        .background(fill(line.kind, chosen: chosen))
        .contentShape(Rectangle())
        // The whole line is the target; copying is in the context menu, since selectable
        // text would take the click.
        .onTapGesture { choose(line, in: hunk) }
        .contextMenu { copyMenu(line) }
        .help(line.isChange ? "Click to choose this line, ⇧-click to choose a range" : "")
    }

    private func sideBySideRow(_ row: GitDiffRow, hunk: GitHunk) -> some View {
        HStack(alignment: .top, spacing: 0) {
            half(row.left, number: row.left?.oldNumber, hunk: hunk)
            Rectangle().fill(GitBudTheme.stroke).frame(width: 1)
            half(row.right, number: row.right?.newNumber, hunk: hunk)
        }
    }

    @ViewBuilder
    private func half(_ line: GitDiffLine?, number value: Int?, hunk: GitHunk) -> some View {
        if let line {
            let chosen = line.isChange && selection.contains(hunk, line: line.index)
            HStack(alignment: .top, spacing: 0) {
                number(value)
                mark(line, chosen: chosen)
                Text(line.text.isEmpty ? " " : line.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
            }
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(fill(line.kind, chosen: chosen))
            .contentShape(Rectangle())
            .onTapGesture { choose(line, in: hunk) }
            .contextMenu { copyMenu(line) }
        } else {
            // The other side has no line here: a quiet blank, so the pair still lines up.
            Color.primary.opacity(0.03)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Pieces

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: Self.gutter, alignment: .trailing)
            .padding(.trailing, 6)
    }

    /// The +/- sign, or a check when the line is chosen.
    private func mark(_ line: GitDiffLine, chosen: Bool) -> some View {
        Group {
            if chosen {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            } else {
                Text(line.kind == .addition ? "+" : line.kind == .removal ? "−" : " ")
                    .foregroundStyle(line.kind == .addition ? Color.green : line.kind == .removal ? Color.red : Color.secondary)
            }
        }
        .frame(width: 18)
    }

    private func fill(_ kind: GitDiffLine.Kind, chosen: Bool) -> Color {
        if chosen { return Color.accentColor.opacity(0.26) }
        switch kind {
        case .addition: return Color.green.opacity(0.12)
        case .removal: return Color.red.opacity(0.12)
        case .context: return .clear
        }
    }

    @ViewBuilder
    private func copyMenu(_ line: GitDiffLine) -> some View {
        Button("Copy Line") { copy(line.text) }
        Button("Copy File Changes") {
            copy(diff.hunks.flatMap { [$0.header] + $0.lines.filter { !$0.isEmpty } }.joined(separator: "\n"))
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Choosing

    private func choose(_ line: GitDiffLine, in hunk: GitHunk) {
        guard line.isChange else { return }
        // ⇧-click: everything changed between the last click and this one, in the same hunk.
        // The range takes the state the line clicked first already has.
        if NSEvent.modifierFlags.contains(.shift), let anchor, anchor.hunkID == hunk.id {
            let target = selection.contains(hunk, line: anchor.index)
            let range = min(anchor.index, line.index)...max(anchor.index, line.index)
            for index in range where GitPatchBuilder.isChange(hunk.lines, at: index)
                && selection.contains(hunk, line: index) != target {
                selection.toggle(hunk, line: index)
            }
        } else {
            selection.toggle(hunk, line: line.index)
        }
        anchor = line
    }
}
