import GitBudCore
import GitKittieKit
import SwiftUI

/// Pull requests from the connected provider: the list, and the review.
struct PullRequestsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if !isConnected {
            EmptyPanel(
                title: "No provider connected",
                message: "Connect an account and pick a repository in Settings to review pull requests here."
            )
            .overlay(alignment: .bottom) {
                Button("Open Settings") { openSettings() }
                    .padding(.bottom, 60)
            }
        } else {
            HSplitView {
                list
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
                PullRequestReviewView()
                    .frame(minWidth: 480)
            }
        }
    }

    private var isConnected: Bool {
        model.selectedProviderRepository != nil &&
        !model.remoteAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pull Requests")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(model.selectedProviderRepository?.fullName ?? "")
                        .font(.caption)
                        .foregroundStyle(GitBudTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    model.loadProviderPullRequests()
                } label: {
                    if model.isLoadingPullRequests {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("Reload open pull requests")
                .disabled(model.isLoadingPullRequests)
            }
            .padding(16)

            Divider().overlay(.white.opacity(0.08))

            ScrollView {
                LazyVStack(spacing: 4) {
                    if model.providerPullRequests.isEmpty {
                        EmptyPanel(
                            title: "No open pull requests",
                            message: "Reload to fetch the latest from the provider."
                        )
                        .padding(.top, 30)
                    } else {
                        ForEach(model.providerPullRequests) { pullRequest in
                            row(pullRequest)
                        }
                    }
                }
                .padding(12)
            }

            Divider().overlay(.white.opacity(0.08))

            Button {
                model.createDraftPullRequest()
            } label: {
                if model.isCreatingPullRequest {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else {
                    Label("Create Draft PR from Current Branch", systemImage: "arrow.triangle.pull")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(model.isCreatingPullRequest)
            .padding(16)
        }
        .background(GitBudTheme.panel)
    }

    private func row(_ pullRequest: GitHubPullRequest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("#\(pullRequest.number)")
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(GitBudTheme.secondaryText)
                Text(pullRequest.title)
                    .font(.subheadline)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Text("\(pullRequest.head) → \(pullRequest.base)")
                    .font(.caption2)
                    .lineLimit(1)
                if pullRequest.isDraft {
                    Text("Draft")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.white.opacity(0.10), in: Capsule())
                }
            }
            .foregroundStyle(GitBudTheme.secondaryText)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .gitBudPanelRow(
            isSelected: model.selectedProviderPullRequestNumber == pullRequest.number,
            cornerRadius: 8,
            baseOpacity: 0.045
        )
        .onTapGesture { model.selectProviderPullRequest(pullRequest) }
        .contextMenu {
            Button {
                gitBudCopyToPasteboard(pullRequest.url.absoluteString)
            } label: {
                Label("Copy Link", systemImage: "link")
            }
            Link(destination: pullRequest.url) {
                Label("Open on Provider", systemImage: "arrow.up.forward.app")
            }
        }
    }
}
