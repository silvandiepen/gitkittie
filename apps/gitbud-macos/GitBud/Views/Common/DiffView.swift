import GitBudCore
import GitKittieKit
import SwiftUI


struct DiffView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.hasConflicts {
                    ConflictPanel()
                }

                if let diff = model.selectedDiff {
                    Text(diff.path)
                        .font(.headline)
                    ForEach(diff.hunks) { hunk in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) {
                                Button {
                                    model.toggleSplitHunk(hunk)
                                } label: {
                                    Image(systemName: model.selectedSplitHunkIDs.contains(hunk.id) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(model.selectedSplitHunkIDs.contains(hunk.id) ? Color.accentColor : GitBudTheme.secondaryText)
                                }
                                .buttonStyle(.plain)
                                .help("Include this hunk in a split commit")

                                Text(hunk.header)
                                    .font(.caption.monospaced().weight(.bold))
                                    .foregroundStyle(.blue)

                                Spacer(minLength: 0)
                            }
                            .padding(.bottom, 6)
                            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(lineColor(line))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 1)
                            }
                        }
                        .padding(10)
                        .background(.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 8))
                    }
                } else {
                    EmptyPanel(title: "No diff selected", message: "Select a changed file to inspect its patch.")
                }
            }
            .padding(14)
        }
        .background(.black.opacity(0.10))
    }

    private func lineColor(_ line: String) -> Color {
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        return GitBudTheme.primaryText
    }
}

struct ConflictPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 10) {
            Label("Conflicts need attention", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)
            ForEach(model.conflicts) { conflict in
                VStack(alignment: .leading, spacing: 8) {
                    Text(conflict.path)
                        .font(.caption.weight(.bold))
                    ForEach(conflict.sections) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.side.rawValue)
                                .font(.caption.weight(.bold))
                            ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption.monospaced())
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(section.side == .yourChange ? Color.blue.opacity(0.16) : Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                    }
                    HStack(spacing: 8) {
                        Button("Use Your change") {
                            model.resolveConflict(conflict, taking: .yourChange)
                        }
                        Button("Use REmote change") {
                            model.resolveConflict(conflict, taking: .remoteChange)
                        }
                        Button("Use Edit") {
                            model.resolveConflictWithDraft(conflict)
                        }
                    }
                    .buttonStyle(.bordered)

                    TextEditor(text: Binding(
                        get: { model.conflictDrafts[conflict.path] ?? "" },
                        set: { model.conflictDrafts[conflict.path] = $0 }
                    ))
                    .font(.caption.monospaced())
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 90)
                    .padding(6)
                    .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)) }
                }
            }
            HStack(spacing: 8) {
                Button(model.conflictContinueButtonTitle) {
                    model.continueRebase()
                }
                Button(model.conflictAbortButtonTitle) {
                    model.abortRebase()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.orange.opacity(0.28)) }
    }
}

