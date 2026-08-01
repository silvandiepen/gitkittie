import AppKit
import GitBudCore
import GitKittieKit
import SwiftUI

/// The default surface: the commit graph, and whatever you clicked on.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var pending: GitBudAction?

    var body: some View {
        HSplitView {
            graphColumn
                .frame(minWidth: 380, idealWidth: 520)
            CommitDetailView()
                .frame(minWidth: 420)
        }
        .actionSheet(pending: $pending)
    }

    private var graphColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HistoryToolbar()
            Divider().overlay(.white.opacity(0.08))
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        CommitRow(row: row, laneCount: laneCount, pending: $pending)
                    }

                    if model.canLoadMoreHistory {
                        Button {
                            model.loadMoreHistory()
                        } label: {
                            HStack {
                                if model.isLoadingMoreHistory {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.down.circle")
                                }
                                Text(model.isLoadingMoreHistory ? "Loading…" : "Load older commits")
                                    .font(.caption.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(GitBudTheme.secondaryText)
                        .onAppear { model.loadMoreHistory() }
                    }

                    if rows.isEmpty {
                        EmptyPanel(
                            title: "No commits",
                            message: model.historySearchDidRun
                                ? "No history matches that search."
                                : "This repository has no commits yet."
                        )
                        .padding(.top, 40)
                    }
                }
            }
        }
    }

    private var rows: [GitGraphRow] { model.graphRows }

    /// One width for every row, so the dots line up into columns.
    private var laneCount: Int {
        min(rows.map(\.laneCount).max() ?? 1, 10)
    }
}

private struct HistoryToolbar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("History")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(GitBudTheme.secondaryText)
            }

            Spacer()

            TextField("Search", text: $model.historySearchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .onSubmit { model.searchHistory() }

            Picker("Mode", selection: $model.historySearchMode) {
                Text("Message").tag(GitHistorySearchMode.message)
                Text("Changes").tag(GitHistorySearchMode.changes)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 140)

            if model.isSearchingHistory {
                ProgressView().controlSize(.small)
            } else if model.historySearchDidRun || model.hasHistorySearch {
                Button {
                    model.clearHistorySearch()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(GitBudTheme.secondaryText)
                .help("Clear search")
            }
        }
        .padding(16)
    }

    private var subtitle: String {
        if model.historySearchDidRun {
            return "\(model.historySearchResults.count) matches"
        }
        if model.selectedCommitIDs.count > 1 {
            return "\(model.selectedCommitIDs.count) of \(model.commits.count) commits selected"
        }
        return "\(model.commits.count) commits"
    }
}
