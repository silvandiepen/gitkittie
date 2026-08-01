import GitBudCore
import GitKittieKit
import SwiftUI

/// ⌘K. Every verb that applies to the current selection, filterable, keyboard-first.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var pending: GitBudAction?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(GitBudTheme.secondaryText)
                TextField("Run a command", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFieldFocused)
                    .onSubmit { run(matches.first) }
            }
            .padding(16)

            Divider().overlay(.white.opacity(0.08))

            if let scope {
                Text(scope)
                    .font(.caption)
                    .foregroundStyle(GitBudTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }

            ScrollView {
                LazyVStack(spacing: 3) {
                    if matches.isEmpty {
                        Text("No matching commands")
                            .font(.callout)
                            .foregroundStyle(GitBudTheme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    } else {
                        ForEach(matches) { action in
                            Button {
                                run(action)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: action.icon)
                                        .frame(width: 20)
                                        .foregroundStyle(action.isDestructive ? .red : Color.accentColor)
                                    Text(action.title)
                                        .font(.callout)
                                    Spacer()
                                    if let reason = action.disabledReason {
                                        Text(reason)
                                            .font(.caption2)
                                            .foregroundStyle(GitBudTheme.secondaryText)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .gitBudPanelRow(baseOpacity: 0.03)
                            }
                            .buttonStyle(.plain)
                            .disabled(!action.isEnabled)
                            .opacity(action.isEnabled ? 1 : 0.45)
                        }
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 520)
        .background(GitBudTheme.panel)
        .foregroundStyle(GitBudTheme.primaryText)
        .actionSheet(pending: $pending)
        .onAppear { isFieldFocused = true }
    }

    /// What the listed verbs would act on, so the palette is never ambiguous.
    private var scope: String? {
        if let commit = model.focusedCommit {
            if model.selectedCommitIDs.count > 1 {
                return "\(model.selectedCommitIDs.count) commits selected · focused on \(commit.shortID)"
            }
            return "Commit \(commit.shortID) — \(commit.subject)"
        }
        return model.branchSummary?.currentBranch.map { "Branch \($0)" }
    }

    private var matches: [GitBudAction] {
        let all = GitBudActions.all(for: model)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    private func run(_ action: GitBudAction?) {
        guard let action, action.isEnabled else { return }
        if action.needsSheet {
            pending = action
        } else {
            action.perform("")
            dismiss()
        }
    }
}
