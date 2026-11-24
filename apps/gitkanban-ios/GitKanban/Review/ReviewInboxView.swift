import GitKanbanKit
import GitKittieKit
import SwiftUI

// Reviews across every board: what the home screen's Reviews row opens.

/// Every board's review requests, boards with something waiting first. "Review All"
/// walks through the waiting ones one after another.
struct ReviewInboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var run: ReviewRun?
    @State private var showDecided = false

    var body: some View {
        List {
            if model.reviewInbox.isEmpty {
                if model.isLoadingReviewInbox {
                    HStack(spacing: 10) { ProgressView(); Text("Looking for reviews").foregroundStyle(.secondary) }
                        .listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView("No review requests", systemImage: "checkmark.seal",
                                           description: Text("Agents haven't asked for a review on any of your boards."))
                        .listRowBackground(Color.clear)
                }
            } else if model.pendingReviewTotal == 0 {
                Section {
                    Label("Nothing is waiting for you", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
            } else {
                Section {
                    Button {
                        run = ReviewRun(refs: model.openReviewRequests.map(\.ref))
                    } label: {
                        Label("Review All (\(model.openReviewRequests.count))", systemImage: "play.fill")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityIdentifier("reviewAllButton")
                } footer: {
                    Text("\(model.pendingReviewTotal) item\(model.pendingReviewTotal == 1 ? "" : "s") waiting in \(model.openReviewRequests.count) request\(model.openReviewRequests.count == 1 ? "" : "s").")
                }
            }
            ForEach(model.reviewInbox) { board in
                let requests = showDecided ? board.requests : board.open
                if !requests.isEmpty {
                    Section {
                        ForEach(requests) { request in
                            NavigationLink(value: request.ref) { ReviewRequestRow(request: request) }
                                .reviewRequestActions(request)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: board.icon ?? BoardAppearance.defaultIcon).font(.caption2)
                            Text(board.boardName).textCase(nil)
                        }
                    }
                }
            }
            if model.hasReviews {
                Section {
                    Toggle("Show decided requests", isOn: $showDecided)
                }
            }
        }
        .themedList()
        .navigationTitle("Reviews")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: ReviewRef.self) { ref in ReviewDetailView(ref: ref) }
        .refreshable { await model.loadReviewInbox() }
        .task { if !model.hasLoadedReviewInbox { await model.loadReviewInbox() } }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        .fullScreenCover(item: $run) { run in
            ReviewRunView(refs: run.refs).environment(model)
        }
    }
}

/// The requests one run goes through: fixed when it starts, so deciding the last item
/// of a request does not pull it out from under the reviewer.
struct ReviewRun: Identifiable {
    let id = UUID()
    let refs: [ReviewRef]
}

/// One request after another, with where you are and a way on.
struct ReviewRunView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let refs: [ReviewRef]
    @State private var index = 0
    @State private var jump = 0
    /// What the reviewer was about to do when items were found without an answer.
    @State private var leaving: Leaving?

    private enum Leaving { case close, next }

    private var pendingHere: Int { model.reviewRequest(refs[index])?.summary.pending ?? 0 }
    private var isLast: Bool { index >= refs.count - 1 }

    private func leave(_ how: Leaving) {
        switch how {
        case .close: dismiss()
        case .next: if isLast { dismiss() } else { index += 1 }
        }
    }

    var body: some View {
        NavigationStack {
            ReviewDetailView(ref: refs[index], embedded: true, jumpToUnanswered: jump)
                .id(refs[index])
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { if pendingHere > 0 { leaving = .close } else { dismiss() } }
                    }
                    ToolbarItem(placement: .principal) {
                        Text("Request \(index + 1) of \(refs.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            .accessibilityIdentifier("reviewRunPosition")
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 12) {
                        Button { index -= 1 } label: { Image(systemName: "chevron.left").frame(width: 44, height: 36) }
                            .buttonStyle(.bordered)
                            .disabled(index == 0)
                            .accessibilityLabel("Previous request")
                        Button {
                            if pendingHere > 0 { leaving = .next } else { leave(.next) }
                        } label: {
                            Text(isLast ? "Finish" : "Next Request")
                                .font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(pendingHere > 0 ? .gray : .accentColor)
                        .accessibilityIdentifier("reviewNextButton")
                    }
                    .padding(.horizontal).padding(.vertical, 10)
                    .background(.bar)
                }
                .confirmationDialog(
                    "\(pendingHere) item\(pendingHere == 1 ? " has" : "s have") no answer yet",
                    isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } }), titleVisibility: .visible
                ) {
                    Button("Continue Reviewing") { jump += 1 }
                    Button(leaving == .close ? "Close Anyway" : (isLast ? "Finish Anyway" : "Skip to Next Request"), role: .destructive) {
                        if let leaving { leave(leaving) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("They stay waiting, and show first when you open this request again.")
                }
        }
    }
}
