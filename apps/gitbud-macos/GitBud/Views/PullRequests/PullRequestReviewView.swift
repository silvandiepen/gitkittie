import GitBudCore
import GitKittieKit
import SwiftUI

/// Reviewing a pull request: its files, their patches, the inline threads, and the
/// verdict. All of this existed only in dead code before.
struct PullRequestReviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 0) {
            if let pullRequest = model.selectedProviderPullRequest {
                header(pullRequest)
                Divider().overlay(.white.opacity(0.08))

                if let summary = model.providerPullRequestReviewSummary {
                    stats(summary)
                    Divider().overlay(.white.opacity(0.08))
                    HSplitView {
                        fileList(summary)
                            .frame(minWidth: 200, idealWidth: 250)
                        patchAndComments
                            .frame(minWidth: 320)
                    }
                    Divider().overlay(.white.opacity(0.08))
                    reviewBar
                } else {
                    EmptyPanel(
                        title: "Review state not loaded",
                        message: "Load the review to see files, comments, and mergeability."
                    )
                }
            } else {
                EmptyPanel(
                    title: "Select a pull request",
                    message: "Pick one from the list to review it."
                )
            }
        }
    }

    private func header(_ pullRequest: GitHubPullRequest) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("#\(pullRequest.number)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(GitBudTheme.secondaryText)
                Text(pullRequest.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text("\(pullRequest.head) → \(pullRequest.base)")
                    .font(.caption)
                    .foregroundStyle(GitBudTheme.secondaryText)
            }
            Spacer()
            Button {
                model.loadSelectedProviderPullRequestReviewSummary()
            } label: {
                if model.isLoadingPullRequestReviewSummary {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Load Review", systemImage: "checklist.checked")
                }
            }
            .disabled(model.isLoadingPullRequestReviewSummary)
            Link(destination: pullRequest.url) {
                Image(systemName: "arrow.up.forward.app")
            }
            .help("Open on the provider")
        }
        .padding(16)
    }

    private func stats(_ summary: GitHubPullRequestReviewSummary) -> some View {
        HStack(spacing: 8) {
            CompactMetric("Files", summary.changedFiles)
            CompactMetric("Commits", summary.commitCount)
            CompactMetric("Added", summary.additions)
            CompactMetric("Removed", summary.deletions)
            CompactMetric("Approvals", summary.approvals)
            CompactMetric("Changes", summary.requestedChanges)
            if let mergeable = summary.mergeable {
                StatusPill(
                    title: mergeable ? "Mergeable" : (summary.mergeableState ?? "Conflicted"),
                    color: mergeable ? .green : .orange
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func fileList(_ summary: GitHubPullRequestReviewSummary) -> some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(summary.files) { file in
                    HStack(spacing: 6) {
                        Text(file.path)
                            .font(.caption)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        Text("+\(file.additions)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.green)
                        Text("−\(file.deletions)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.red)
                    }
                    .padding(8)
                    .contentShape(Rectangle())
                    .gitBudPanelRow(
                        isSelected: model.selectedProviderPullRequestFilePath == file.path,
                        cornerRadius: 7,
                        baseOpacity: 0.045
                    )
                    .onTapGesture { model.selectProviderPullRequestFile(file) }
                }
            }
            .padding(10)
        }
    }

    private var patchAndComments: some View {
        @Bindable var model = model

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let file = model.selectedProviderPullRequestFile {
                    Text(file.patch ?? "No patch available for this file.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(GitBudTheme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Divider().overlay(.white.opacity(0.08))

                    ForEach(model.selectedProviderPullRequestFileComments) { comment in
                        commentThread(comment)
                    }

                    newCommentBox
                } else {
                    Text("Select a file to read its patch and comments.")
                        .font(.callout)
                        .foregroundStyle(GitBudTheme.secondaryText)
                }
            }
            .padding(16)
        }
    }

    private func commentThread(_ comment: GitHubPullRequestInlineComment) -> some View {
        @Bindable var model = model
        let isSelected = model.selectedProviderInlineCommentID == comment.id

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(comment.authorLogin)
                    .font(.caption.weight(.bold))
                if let line = comment.line ?? comment.originalLine {
                    Text("line \(line)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(GitBudTheme.secondaryText)
                }
                Spacer()
            }
            Text(comment.body)
                .font(.callout)
                .foregroundStyle(GitBudTheme.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if isSelected {
                HStack(spacing: 8) {
                    TextField("Reply", text: $model.providerInlineReplyDraft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    Button {
                        model.postProviderInlineCommentReply()
                    } label: {
                        if model.isPostingPullRequestInlineReply {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrowshape.turn.up.left")
                        }
                    }
                    .help("Reply to this comment")
                    .disabled(
                        model.providerInlineReplyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        model.isPostingPullRequestInlineReply
                    )
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .gitBudPanelRow(isSelected: isSelected, cornerRadius: 8, baseOpacity: 0.045)
        .onTapGesture { model.selectProviderInlineComment(comment) }
    }

    private var newCommentBox: some View {
        @Bindable var model = model

        return VStack(alignment: .leading, spacing: 8) {
            Text("Add an inline comment")
                .font(.caption.weight(.bold))
                .foregroundStyle(GitBudTheme.secondaryText)

            HStack(spacing: 8) {
                TextField("Line", text: $model.providerInlineCommentLineText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Picker("Side", selection: $model.providerInlineCommentSide) {
                    Text("New").tag("RIGHT")
                    Text("Old").tag("LEFT")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 120)
                Spacer()
            }

            TextField("Comment", text: $model.providerInlineCommentDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)

            Button {
                model.postProviderInlineComment()
            } label: {
                if model.isPostingPullRequestInlineComment {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else {
                    Label("Add Comment", systemImage: "plus.bubble")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(
                model.providerInlineCommentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                Int(model.providerInlineCommentLineText.trimmingCharacters(in: .whitespacesAndNewlines)) == nil ||
                model.isPostingPullRequestInlineComment
            )
        }
        .panelCard()
    }

    private var reviewBar: some View {
        @Bindable var model = model

        return VStack(alignment: .leading, spacing: 8) {
            if let review = model.providerSubmittedReview {
                Label("\(review.state) by \(review.authorLogin)", systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            HStack(spacing: 8) {
                TextField("Review summary", text: $model.providerReviewBody, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)

                Button {
                    model.submitProviderPullRequestReview(.approve)
                } label: {
                    Label("Approve", systemImage: "checkmark.seal")
                }
                .disabled(model.isSubmittingPullRequestReview)

                Button {
                    model.submitProviderPullRequestReview(.comment)
                } label: {
                    Label("Comment", systemImage: "text.bubble")
                }
                .disabled(
                    model.isSubmittingPullRequestReview ||
                    model.providerReviewBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                Button(role: .destructive) {
                    model.submitProviderPullRequestReview(.requestChanges)
                } label: {
                    Label("Request Changes", systemImage: "exclamationmark.bubble")
                }
                .disabled(
                    model.isSubmittingPullRequestReview ||
                    model.providerReviewBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                if model.isSubmittingPullRequestReview {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(16)
    }
}
