import AVKit
import GitKanbanKit
import GitKittieKit
import ImageIO
import QuickLook
import SwiftUI
import UIKit

// Asset review. A board has review requests when its review folder (its `review_path`,
// or `review/` inside the board) holds `<request>/review.md` folders. They are reached
// from the open board, from a card, and from the home screen for all boards at once.
// Decisions, answers to questions and comments are written back into `review.md` through
// the board source.

/// All review requests for the open board, open ones first.
struct ReviewListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// When set, only requests for this card are listed.
    var cardID: String?

    private var requests: [ReviewRequest] {
        guard let cardID else { return model.reviews }
        return model.reviews.filter { $0.card == cardID }
    }

    var body: some View {
        List {
            Group {
                if requests.isEmpty {
                    ContentUnavailableView("No review requests", systemImage: "checkmark.seal",
                                           description: Text("Agents haven't asked for a review here yet."))
                        .listRowBackground(Color.clear)
                }
                ForEach(requests) { request in
                    NavigationLink(value: request.ref) {
                        ReviewRequestRow(request: request)
                    }
                    .reviewRequestActions(request)
                }
            }
            // Rows on the navy, not the system grey (GITKITTIE-095).
            .themedRows()
        }
        .themedList()
        .navigationTitle(cardID.map { "Reviews · \($0)" } ?? "Reviews")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: ReviewRef.self) { ref in
            ReviewDetailView(ref: ref)
        }
        .refreshable { await model.loadReviews() }
        .safeAreaInset(edge: .bottom, spacing: 0) { SyncFailuresBanner() }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
    }
}

/// What can be done with a whole request without opening it: long-press its row for every
/// answer, or swipe — right to approve everything waiting, left to reject or ask for changes.
/// Each decides every file still waiting, in one write. Questions are never answered this
/// way: each needs its own answer, in the request.
private struct ReviewRequestActions: ViewModifier {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    @State private var commenting: ReviewRequest?
    @State private var removing: ReviewRequest?
    @State private var askingChanges: ReviewCommentRequest?

    func body(content: Content) -> some View {
        let waiting = request.summary.pendingItems
        let questions = request.summary.unanswered
        content
            .contextMenu {
                if waiting > 0 {
                    Button("Approve All Waiting Files (\(waiting))", systemImage: "checkmark") { decide(.approved) }
                    Button("Ask Changes on All Waiting Files", systemImage: "pencil") { decide(.changesRequested) }
                    Button("Reject All Waiting Files", systemImage: "xmark", role: .destructive) { decide(.rejected) }
                }
                if questions > 0 {
                    Text("Open the request to answer \(questions == 1 ? "its question" : "its \(questions) questions")")
                } else if waiting == 0 {
                    Text("Nothing is waiting in this request")
                }
                ReviewRequestCommands(request: request, commenting: $commenting, removing: $removing)
            }
            .reviewRequestPrompts(commenting: $commenting, removing: $removing)
            .sheet(item: $askingChanges) { ReviewCommentSheet(request: $0) }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if waiting > 0 {
                    Button { decide(.approved) } label: { Label("Approve All", systemImage: "checkmark") }.tint(.green)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if waiting > 0 {
                    Button(role: .destructive) { decide(.rejected) } label: { Label("Reject All", systemImage: "xmark") }
                    Button { decide(.changesRequested) } label: { Label("Changes", systemImage: "pencil") }.tint(.orange)
                }
            }
    }

    private func decide(_ status: ReviewStatus) {
        if status.needsComment {
            // Asking for changes says what to change: one message for every waiting file.
            let request = request
            askingChanges = ReviewCommentRequest(
                purpose: .changes(files: request.summary.pendingItems), subject: request.title,
                suggestions: request.commentSuggestions(),
                send: { text in
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    Task { await model.decideAll(request, status: .changesRequested, comment: text) }
                })
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { await model.decideAll(request, status: status) }
    }
}

extension View {
    /// Long-press and swipe actions that answer a whole review request at once.
    func reviewRequestActions(_ request: ReviewRequest) -> some View {
        modifier(ReviewRequestActions(request: request))
    }
}

/// What else can be done with a whole request, as on the Mac: one comment on every file,
/// its link and path, and removing it. Used in the row's long-press menu and in the request.
struct ReviewRequestCommands: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let request: ReviewRequest
    @Binding var commenting: ReviewRequest?
    @Binding var removing: ReviewRequest?

    var body: some View {
        if request.summary.items > 0 {
            Section {
                Button("Comment on All Files…", systemImage: "text.bubble") { commenting = request }
            }
        }
        Section {
            let link = model.reviewLink(request)
            if let link, !link.isFileURL {
                Button("Copy Link to Request", systemImage: "link") { UIPasteboard.general.url = link }
                Button("Open in Browser", systemImage: "safari") { openURL(link) }
            }
            Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = model.reviewPath(request) }
        }
        Section {
            Button("Remove Request…", systemImage: "trash", role: .destructive) { removing = request }
        }
    }
}

/// The two prompts the request commands open.
private struct ReviewRequestPrompts: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var commenting: ReviewRequest?
    @Binding var removing: ReviewRequest?
    var onRemoved: () -> Void
    @State private var sheet: ReviewCommentRequest?

    func body(content: Content) -> some View {
        content
            .onChange(of: commenting) { _, request in
                guard let request else { return }
                sheet = ReviewCommentRequest(
                    purpose: .comment(files: request.summary.items), subject: request.title,
                    suggestions: request.commentSuggestions(),
                    send: { text in Task { await model.commentAll(request, text: text) } })
            }
            .sheet(item: $sheet, onDismiss: { commenting = nil }) { ReviewCommentSheet(request: $0) }
            .confirmationDialog("Remove “\(removing?.title ?? "")”?",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { request in
                Button("Remove Request", role: .destructive) {
                    Task {
                        await model.removeReview(request)
                        onRemoved()
                    }
                }
            } message: { request in
                Text((request.items.isEmpty ? "The request is deleted from the board."
                      : "The request and its \(request.items.count) files are deleted from the board.")
                     + " Your answers go with it; git keeps the history.")
            }
    }
}

extension View {
    func reviewRequestPrompts(commenting: Binding<ReviewRequest?>, removing: Binding<ReviewRequest?>,
                              onRemoved: @escaping () -> Void = {}) -> some View {
        modifier(ReviewRequestPrompts(commenting: commenting, removing: removing, onRemoved: onRemoved))
    }
}

struct ReviewRequestRow: View {
    let request: ReviewRequest

    var body: some View {
        let s = request.summary
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(request.title).font(.body.weight(.medium))
                Spacer(minLength: 8)
                if s.pending > 0 {
                    Text("\(s.pending)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            }
            if request.problem != nil {
                Label("Can't be read: its review.md is not valid", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            } else if let question = request.question {
                Text(MarkdownPage.inline(question)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(summaryLine(request)).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func summaryLine(_ request: ReviewRequest) -> String {
        let s = request.summary
        var parts: [String] = []
        if let card = request.card { parts.append(card) }
        if s.pendingItems > 0 { parts.append("\(s.pendingItems) waiting") }
        if s.approved > 0 { parts.append("\(s.approved) approved") }
        if s.changesRequested > 0 { parts.append("\(s.changesRequested) changes") }
        if s.rejected > 0 { parts.append("\(s.rejected) rejected") }
        if let questions = s.questionsDescription { parts.append(questions) }
        if parts.isEmpty || (parts.count == 1 && request.card != nil) { parts.append("\(s.items) item\(s.items == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// One page of a request: a question to answer or a file to judge (`ReviewEntry`, in the
/// order both apps show them: questions first, then the files group by group).
private typealias ReviewPage = ReviewEntry

private extension ReviewEntry {
    /// "2 items and 1 question have no answer yet".
    static func noAnswerTitle(_ pages: [ReviewEntry]) -> String {
        let questions = pages.filter { if case .question = $0 { return true } else { return false } }.count
        let total = pages.count
        return "\(ReviewSummary.describe(items: total - questions, questions: questions)) \(total == 1 ? "has" : "have") no answer yet"
    }
}

/// One request as slides: one question or item per page, swiped through. Opening a request
/// shows what has no answer yet; closing with some left asks first.
struct ReviewDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ref: ReviewRef
    /// Inside a run the surrounding view has its own way out, and asks before leaving.
    var embedded = false
    /// Counted up from outside to jump to the first page without an answer.
    var jumpToUnanswered = 0

    /// The pages on show, fixed when the request opens (or the filter changes) so an
    /// answered slide does not vanish under your thumb.
    @State private var slideIDs: Set<String> = []
    @State private var selection = ""
    /// Which pages show: what waits, what is answered, or everything. Remembered.
    @AppStorage("reviewsFilter") private var filter: ReviewFilter = .waiting
    @State private var showsNotes = false
    @State private var confirmClose = false
    @State private var commenting: ReviewRequest?
    @State private var removing: ReviewRequest?
    /// Select mode: the files on show as a grid, to choose several and act on them at once.
    @State private var selecting = false
    @State private var chosen: Set<String> = []
    /// The comment sheet for the chosen files: Changes (which needs a message) or a comment.
    @State private var selectionSheet: ReviewCommentRequest?
    /// The full-screen viewer, open at the file whose picture was tapped.
    @State private var fullScreen: ReviewFullScreenStart?

    private var request: ReviewRequest? { model.reviewRequest(ref) }

    /// The files on show, in order: what Select works on.
    private func shownItems(_ request: ReviewRequest) -> [ReviewItem] {
        slides(request).compactMap { page in
            if case .item(let item) = page { return item } else { return nil }
        }
    }

    private func slides(_ request: ReviewRequest) -> [ReviewPage] {
        request.entries.filter { slideIDs.contains($0.id) }
    }

    private func unanswered(_ request: ReviewRequest) -> [ReviewPage] {
        slides(request).filter(\.isWaiting)
    }

    var body: some View {
        Group {
            if let request {
                let pages = slides(request)
                // Where the page on screen is, worked out once: every page asks whether it is
                // near it, and a request can have hundreds of pages.
                let position = pages.firstIndex { $0.id == selection } ?? 0
                VStack(spacing: 0) {
                    header(request, pages: pages, position: position)
                    if let problem = request.problem {
                        ContentUnavailableView {
                            Label("This request can't be read", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text("Its review.md has frontmatter that is not valid YAML. \(problem) The agent that wrote it has to fix it.")
                        }
                    } else if pages.isEmpty {
                        ContentUnavailableView {
                            Label(filter == .answered ? "Nothing answered yet" : "Nothing waits here", systemImage: "checkmark.seal")
                        } actions: {
                            Button("Show All") { filter = .all }
                        }
                    } else if selecting {
                        ReviewSelectGrid(request: request, items: shownItems(request), chosen: $chosen)
                    } else {
                        TabView(selection: $selection) {
                            ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                                Group {
                                    switch page {
                                    case .question(let question):
                                        QuestionSlide(request: request, question: question, onAnswered: { advance(after: page.id) })
                                    case .item(let item):
                                        // Only the slide on screen and its neighbours hold their
                                        // picture: a request can have dozens of large images.
                                        ReviewSlide(request: request, item: item,
                                                    isNear: abs(index - position) <= 1,
                                                    onDecided: { advance(after: page.id) },
                                                    onEnlarge: { openFullScreen(request, at: item.id) })
                                    }
                                }
                                .tag(page.id)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                    }
                }
                .navigationTitle(request.title)
                .onAppear { if slideIDs.isEmpty { load(request) } }
                .onChange(of: filter) { _, _ in load(request) }
                .sheet(isPresented: $showsNotes) { ReviewNotesSheet(request: request).environment(model) }
                .onChange(of: jumpToUnanswered) { _, _ in goToUnanswered(request) }
                .confirmationDialog(
                    ReviewPage.noAnswerTitle(unanswered(request)),
                    isPresented: $confirmClose, titleVisibility: .visible
                ) {
                    Button("Continue Reviewing") { goToUnanswered(request) }
                    Button("Close Anyway", role: .destructive) { dismiss() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("They stay waiting, and show first when you open this request again.")
                }
            } else {
                ContentUnavailableView("Review not found", systemImage: "questionmark.folder")
            }
        }
        .background(Theme.window.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(!embedded)
        .toolbar {
            if selecting {
                ToolbarItem(placement: .topBarLeading) {
                    let all = request.map { shownItems($0).map(\.id) } ?? []
                    let allChosen = !all.isEmpty && Set(all).isSubset(of: chosen)
                    Button(allChosen ? "Deselect All" : "Select All") {
                        chosen = allChosen ? [] : Set(all)
                    }
                    .accessibilityIdentifier("reviewSelectAll")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { endSelecting() }.fontWeight(.semibold)
                        .accessibilityIdentifier("reviewSelectDone")
                }
            } else {
                if !embedded {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            if let request, !unanswered(request).isEmpty { confirmClose = true } else { dismiss() }
                        } label: { Label("Reviews", systemImage: "chevron.left") }
                        .accessibilityIdentifier("reviewBackButton")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let request, !shownItems(request).isEmpty {
                            Button("Select", systemImage: "checkmark.circle") { withAnimation { selecting = true } }
                                .accessibilityIdentifier("reviewSelectFiles")
                        }
                        Picker("Show", selection: $filter) {
                            ForEach(ReviewFilter.allCases) { option in
                                Text("\(option.title) (\(request.map { option.count(in: $0.summary) } ?? 0))").tag(option)
                            }
                        }
                        if let request, !ReviewNotes.blocks(request).isEmpty {
                            Button("Notes", systemImage: "doc.text") { showsNotes = true }
                        }
                        Button("Reload", systemImage: "arrow.clockwise") { Task { await model.refreshReviews() } }
                        if let request {
                            ReviewRequestCommands(request: request, commenting: $commenting, removing: $removing)
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityIdentifier("reviewMoreMenu")
                }
            }
        }
        .reviewRequestPrompts(commenting: $commenting, removing: $removing, onRemoved: { dismiss() })
        .sheet(item: $selectionSheet) { ReviewCommentSheet(request: $0) }
        .fullScreenCover(item: $fullScreen) { start in
            ReviewFullScreenView(ref: ref, start: start).environment(model)
        }
        .safeAreaInset(edge: .bottom) {
            if selecting, let request { selectionBar(request) }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                // Reviews open in a sheet, over the activity mark: a change that could not
                // be sent shows here, with what can be done about it.
                SyncFailuresBanner()
                if let error = model.errorMessage {
                    Text(error).font(.callout).padding(10)
                        .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                        .padding()
                }
            }
        }
    }

    /// What is on show: for "Waiting", the questions and items without an answer, with the
    /// other options of a pick-one group that is still open (a request with nothing waiting
    /// shows everything); for "Answered", what has an answer; or all of it.
    private func load(_ request: ReviewRequest) {
        let hidden = request.hiddenIDs(for: filter)
        let shown = request.entries.filter { entry in
            switch entry {
            case .question(let question): return !hidden.questions.contains(question.id)
            case .item(let item): return !hidden.items.contains(item.id)
            }
        }
        slideIDs = Set(shown.map(\.id))
        if !slideIDs.contains(selection) {
            selection = shown.first(where: \.isWaiting)?.id ?? shown.first?.id ?? ""
        }
    }

    private func endSelecting() {
        withAnimation { selecting = false }
        chosen = []
    }

    /// "N selected" and what can be done with them, each in one write.
    private func selectionBar(_ request: ReviewRequest) -> some View {
        let ids = chosen
        return VStack(spacing: 6) {
            Text(ids.isEmpty ? "Select files" : "\(ids.count) selected")
                .font(.footnote.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                .accessibilityIdentifier("reviewSelectionCount")
            HStack(spacing: 4) {
                selectionAction("Approve", "checkmark", .green) { decideSelection(request, ids, .approved) }
                selectionAction("Changes", "pencil", .orange) { commentOnSelection(request, ids, changes: true) }
                selectionAction("Reject", "xmark", .red) { decideSelection(request, ids, .rejected) }
                selectionAction("Waiting", "arrow.uturn.backward", .secondary) { decideSelection(request, ids, .pending) }
                    .accessibilityLabel("Back to Waiting")
                selectionAction("Comment", "text.bubble", Theme.accent) { commentOnSelection(request, ids, changes: false) }
            }
            .disabled(ids.isEmpty || model.isSaving)
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(Theme.bar.ignoresSafeArea(edges: .bottom))
    }

    private func selectionAction(_ title: String, _ symbol: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.body.weight(.semibold))
                Text(title).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reviewSelection\(title)")
    }

    private func decideSelection(_ request: ReviewRequest, _ ids: Set<String>, _ status: ReviewStatus) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { await model.decide(request, itemIDs: ids, status: status) }
    }

    /// One message for every chosen file: asking for changes (it needs one) or a comment.
    private func commentOnSelection(_ request: ReviewRequest, _ ids: Set<String>, changes: Bool) {
        selectionSheet = ReviewCommentRequest(
            purpose: changes ? .changes(files: ids.count) : .comment(files: ids.count),
            subject: ids.count == 1 ? ids.first : nil,
            suggestions: request.commentSuggestions(),
            send: { text in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Task {
                    if changes {
                        await model.decide(request, itemIDs: ids, status: .changesRequested, comment: text)
                    } else {
                        await model.comment(request, itemIDs: ids, text: text)
                    }
                }
            })
    }

    /// Open the full-screen viewer at a file: its pages are the files on show, in order.
    private func openFullScreen(_ request: ReviewRequest, at itemID: String) {
        fullScreen = ReviewFullScreenStart(pager: ReviewPager(itemIDs: shownItems(request).map(\.id)), itemID: itemID)
    }

    private func goToUnanswered(_ request: ReviewRequest) {
        if let next = unanswered(request).first { withAnimation { selection = next.id } }
    }

    /// After an answer: on to the next page that has none, when there is one.
    private func advance(after id: String) {
        guard let request = model.reviewRequest(ref) else { return }
        let pages = slides(request)
        guard pages.contains(where: { $0.id == id }), let later = ReviewEntry.nextWaiting(after: id, in: pages),
              later.id != id else { return }
        withAnimation { selection = later.id }
    }

    private func header(_ request: ReviewRequest, pages: [ReviewPage], position: Int) -> some View {
        let answered = pages.filter { !$0.isWaiting }.count
        let waiting = pages.count - answered
        let current = pages.indices.contains(position) ? pages[position] : nil
        let nextWaiting = ReviewEntry.nextWaiting(after: current?.id, in: pages)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let question = request.question {
                    Text(MarkdownPage.inline(question)).font(.headline).lineLimit(3)
                }
                Spacer(minLength: 0)
                if !ReviewNotes.blocks(request).isEmpty {
                    Button { showsNotes = true } label: { Label("Notes", systemImage: "doc.text").font(.subheadline) }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("reviewNotesButton")
                }
            }
            // Every page as a tick, waiting ones bright: where the files without an answer
            // are, at a glance. Tap or drag along it to go there.
            ReviewProgressStrip(marks: pages.map(\.mark), position: position) { index in
                if pages.indices.contains(index) { withAnimation { selection = pages[index].id } }
            }
            HStack(spacing: 8) {
                Text("\(position + 1) of \(pages.count)").monospacedDigit()
                if let current { WaitingTag(waiting: current.isWaiting) }
                if case .item(let item)? = current, let group = item.group {
                    Text(ReviewGroupCount.line(request, group: group)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Text("\(answered) of \(pages.count) answered").monospacedDigit()
                    .accessibilityIdentifier("reviewAnsweredCount")
            }
            .font(.caption).foregroundStyle(.secondary)
            if waiting > 0, let nextWaiting, nextWaiting.id != current?.id {
                Button {
                    withAnimation { selection = nextWaiting.id }
                } label: {
                    Label("Next waiting · \(waiting) left", systemImage: "forward.fill")
                        .font(.footnote.weight(.semibold)).monospacedDigit()
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .tint(Theme.accentFill)
                .accessibilityLabel("Next waiting, \(waiting) left")
                .accessibilityIdentifier("reviewNextWaiting")
            }
        }
        .padding(.horizontal).padding(.top, 8).padding(.bottom, 6)
    }
}

/// "Waiting" as a filled tag in the accent; "Answered" quiet beside it.
struct WaitingTag: View {
    let waiting: Bool

    var body: some View {
        Text(waiting ? "Waiting" : "Answered")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(waiting ? AnyShapeStyle(Theme.accentFill) : AnyShapeStyle(Theme.stroke), in: Capsule())
            .foregroundStyle(waiting ? Color.white : Color.secondary)
    }
}

/// How many files of a group still wait, from the whole request (not only what is on show).
enum ReviewGroupCount {
    static func waiting(_ request: ReviewRequest, group: String?) -> (waiting: Int, total: Int) {
        let members = request.items.filter { $0.group == group }
        return (members.filter { $0.status == .pending }.count, members.count)
    }

    /// "trees · 3 of 20 waiting", or "trees · all 20 answered".
    static func line(_ request: ReviewRequest, group: String) -> String {
        let count = waiting(request, group: group)
        return count.waiting == 0 ? "\(group) · all \(count.total) answered" : "\(group) · \(count.waiting) of \(count.total) waiting"
    }
}

private extension ReviewEntry {
    /// What the progress strip draws for this page: an answered question as answered.
    var mark: ReviewStatus {
        switch self {
        case .question(let question): return question.isAnswered ? .approved : .pending
        case .item(let item): return item.status
        }
    }
}

/// Select mode: the request's files as thumbnails, each with a checkmark; tap to choose.
private struct ReviewSelectGrid: View {
    let request: ReviewRequest
    let items: [ReviewItem]
    @Binding var chosen: Set<String>
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// The files on show, group by group, in order.
    private var sections: [(name: String?, items: [ReviewItem])] {
        var result: [(name: String?, items: [ReviewItem])] = []
        for item in items {
            if let last = result.indices.last, result[last].name == item.group {
                result[last].items.append(item)
            } else {
                result.append((item.group, [item]))
            }
        }
        return result
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 170 : 105), spacing: 10)], spacing: 10,
                      pinnedViews: [.sectionHeaders]) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    Section {
                        ForEach(section.items) { item in
                            let isChosen = chosen.contains(item.id)
                            Button {
                                if isChosen { chosen.remove(item.id) } else { chosen.insert(item.id) }
                            } label: {
                                ReviewThumbnail(request: request, item: item, isChosen: isChosen)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(item.id), \(item.status == .pending ? "waiting" : item.status.title)")
                            .accessibilityAddTraits(isChosen ? .isSelected : [])
                            .accessibilityIdentifier("reviewSelectItem-\(item.id)")
                        }
                    } header: {
                        if let name = section.name { groupHeader(name) }
                    }
                }
            }
            .padding(.horizontal).padding(.vertical, 8)
        }
    }

    /// The group's name and how many of its files wait, over the whole request.
    private func groupHeader(_ name: String) -> some View {
        let count = ReviewGroupCount.waiting(request, group: name)
        return HStack(spacing: 8) {
            Text(name.capitalized).font(.subheadline.weight(.semibold))
            if count.waiting > 0 {
                Text("\(count.waiting) waiting").font(.caption.weight(.bold)).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Theme.accentFill, in: Capsule()).foregroundStyle(.white)
            }
            Text(count.waiting == 0 ? "all \(count.total) answered" : "of \(count.total)")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
        }
        .padding(.vertical, 6)
        .background(Theme.window)
    }
}

/// One file in the select grid: a small picture of it, its decision and a checkmark.
private struct ReviewThumbnail: View {
    let request: ReviewRequest
    let item: ReviewItem
    let isChosen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            picture
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                // Chosen: a tinted fill over the picture, with the checkmark.
                .overlay {
                    RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(isChosen ? 0.28 : 0))
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, isChosen ? Color.accentColor : Color.black.opacity(0.25))
                        .shadow(radius: 1)
                        .padding(6)
                }
                // Answered files step back, so the ones that wait stand out in a long grid.
                .opacity(item.status == .pending || isChosen ? 1 : 0.45)
                .overlay(alignment: .bottomLeading) {
                    if item.status == .pending {
                        WaitingTag(waiting: true).padding(6)
                    } else {
                        Image(systemName: ReviewColor.symbol(item.status))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white, ReviewColor.status(item.status))
                            .symbolRenderingMode(.palette)
                            .padding(6)
                    }
                }
            Text(item.id).font(.caption2.weight(.medium)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(item.status == .pending ? .primary : .secondary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var picture: some View {
        switch item.kind {
        case .image, .animation:
            ReviewImage(request: request, file: item.file, maxPixel: 360)
        case .model:
            if let preview = item.preview {
                ReviewImage(request: request, file: preview, maxPixel: 360)
            } else {
                symbol("cube.transparent")
            }
        case .audio: symbol("waveform")
        case .video: symbol("film")
        case .other: symbol("doc")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 30)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One question, filling a page: answered in place, then on to the next page.
private struct QuestionSlide: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    let question: ReviewQuestion
    let onAnswered: () -> Void

    var body: some View {
        ScrollView {
            ReviewQuestionView(question: question, isSaving: model.isSaving, onAnswer: { choices, other, comment in
                await model.answer(request, question: question, choices: choices, other: other, comment: comment)
            }, onAnswered: {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onAnswered()
            })
            .padding(.horizontal).padding(.top, 8).padding(.bottom, 24)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

enum ReviewColor {
    static func status(_ status: ReviewStatus) -> Color {
        switch status {
        case .pending: return .secondary
        case .approved: return .green
        case .rejected: return .red
        case .changesRequested: return .orange
        }
    }

    static func symbol(_ status: ReviewStatus) -> String {
        switch status {
        case .pending: return "circle.dashed"
        case .approved: return "checkmark.circle.fill"
        case .rejected: return "xmark.circle.fill"
        case .changesRequested: return "pencil.circle.fill"
        }
    }
}

/// One item, filling a page: the asset, what was decided, the answer buttons and comments.
private struct ReviewSlide: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    let item: ReviewItem
    /// On screen or next to it: only then is the asset loaded.
    var isNear = true
    let onDecided: () -> Void
    /// The picture was tapped: open the full-screen viewer at this file.
    var onEnlarge: (() -> Void)?
    @State private var draft = ""
    /// The message sheet Changes opens: asking for changes needs one.
    @State private var askingChanges: ReviewCommentRequest?
    @State private var annotating: SharedImage?
    @State private var showsAnnotator = false
    /// The marked-up image of a comment that is shown full screen.
    @State private var enlargedComment: String?
    @State private var isPreparingAnnotation = false
    @FocusState private var composing: Bool

    /// The other options when this item is one of several to choose from.
    private var options: [ReviewItem] {
        guard let group = item.group else { return [] }
        let members = request.items.filter { $0.group == group }
        return members.count > 1 && members.contains(where: \.pickOne) ? members : []
    }
    private var isChoice: Bool { !options.isEmpty }
    private var picked: ReviewItem? { options.first { $0.status == .approved } }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if isChoice { choiceStrip }
                    Group {
                        if isNear { ReviewAssetView(request: request, item: item, onEnlarge: onEnlarge) } else { Color.clear }
                    }
                        .frame(maxWidth: .infinity)
                        .frame(height: max(220, proxy.size.height - (isChoice ? 330 : 270)))
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(outline, lineWidth: item.status == .pending ? 0 : 3)
                        }
                        .overlay(alignment: .topLeading) { verdictBadge.padding(10) }

                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.id).font(.subheadline.weight(.semibold))
                            if let note = item.note {
                                Text(MarkdownPage.inline(note)).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                        if let revises = item.revises {
                            Label("Redo of \(revises)", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    decisionButtons

                    HStack(alignment: .bottom, spacing: 8) {
                        if item.kind == .image {
                            Button { Task { await startAnnotating() } } label: {
                                Group {
                                    if isPreparingAnnotation { ProgressView() } else { Image(systemName: "pencil.tip.crop.circle") }
                                }
                                .font(.title2).frame(width: 36, height: 36)
                            }
                            .accessibilityLabel("Mark up the image")
                            .accessibilityIdentifier("reviewAnnotateButton")
                            .disabled(isPreparingAnnotation || model.isSaving)
                        }
                        TextField("Comment", text: $draft, axis: .vertical)
                            .lineLimit(1...4)
                            .focused($composing)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                        // What was said on other files of this request, to say again in one tap.
                        ReviewCommentSuggestionMenu(suggestions: request.commentSuggestions(excluding: item)) { draft = $0 }
                        Button {
                            let text = draft
                            draft = ""
                            composing = false
                            Task { await model.comment(request, item: item, text: text) }
                        } label: {
                            Image(systemName: "arrow.up.circle.fill").font(.title2)
                        }
                        .accessibilityLabel("Send comment")
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSaving)
                    }

                    ForEach(Array(item.comments.enumerated()), id: \.offset) { _, comment in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(comment.by) · \(ReviewFormat.relative(comment.at))")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(comment.text).font(.callout)
                            if let image = comment.image {
                                ReviewImage(request: request, file: image, maxPixel: 600)
                                    .frame(height: 140)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                                    .onTapGesture { enlargedComment = image }
                            }
                        }
                    }
                }
                .padding(.horizontal).padding(.bottom, 16)
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(item: $askingChanges) { ReviewCommentSheet(request: $0) }
        .fullScreenCover(item: Binding(get: { enlargedComment.map(QuickLookItem.init(file:)) }, set: { enlargedComment = $0?.file })) { shown in
            ImageViewer(request: request, file: shown.file ?? "").environment(model)
        }
        .fullScreenCover(isPresented: $showsAnnotator, onDismiss: {
            // What was marked goes to the agent as a comment with the marked-up image.
            if let finished = annotating, !finished.annotations.isEmpty { sendAnnotations(finished) }
            annotating = nil
        }) {
            if annotating != nil {
                AnnotationEditor(image: Binding(get: { annotating! }, set: { annotating = $0 }))
            }
        }
    }

    private var outline: Color {
        if isChoice, let picked { return picked.id == item.id ? .green : Color.secondary.opacity(0.4) }
        return ReviewColor.status(item.status)
    }

    /// What was decided, written on the asset itself so it cannot be missed.
    @ViewBuilder private var verdictBadge: some View {
        if isChoice, let picked {
            if picked.id == item.id {
                badge("Picked", "checkmark.circle.fill", .green)
            } else {
                badge("Not picked", "circle.slash", .gray)
            }
        } else if item.status != .pending {
            badge(item.status.title, item.status == .approved ? "checkmark.circle.fill" : (item.status == .rejected ? "xmark.circle.fill" : "pencil.circle.fill"),
                  ReviewColor.status(item.status))
        } else {
            // Not decided yet: said as plainly as a decision is, on the picture itself.
            Label("Waiting for you", systemImage: "circle.dashed")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .themedBar(in: Capsule())
                .foregroundStyle(Theme.accentText)
                .accessibilityIdentifier("reviewVerdict")
        }
    }

    private func badge(_ title: String, _ symbol: String, _ color: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.bold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color, in: Capsule())
            .foregroundStyle(.white)
            .accessibilityIdentifier("reviewVerdict")
    }

    /// The options of a pick-one group, with which one is chosen.
    private var choiceStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text((item.group ?? "").capitalized).font(.subheadline.weight(.semibold))
                Text(picked == nil ? "Pick one of \(options.count)" : "Picked: \(picked!.id)")
                    .font(.caption).foregroundStyle(picked == nil ? Color.secondary : Color.green)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        let isPicked = picked?.id == option.id
                        HStack(spacing: 4) {
                            if isPicked { Image(systemName: "checkmark.circle.fill") }
                            Text("\(index + 1). \(option.id)").lineLimit(1)
                        }
                        .font(.caption.weight(option.id == item.id ? .bold : .regular))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(isPicked ? Color.green.opacity(0.2) : Theme.panel, in: Capsule())
                        .overlay { Capsule().strokeBorder(option.id == item.id ? Color.accentColor : .clear, lineWidth: 1.5) }
                        .foregroundStyle(isPicked ? Color.green : (picked != nil ? Color.secondary : Color.primary))
                    }
                }
            }
        }
    }

    private var decisionButtons: some View {
        HStack(spacing: 8) {
            if isChoice {
                decisionButton(picked?.id == item.id ? "Picked" : "Pick This", "checkmark.circle.fill", .approved, tint: .green) {
                    await pickThis()
                    onDecided()
                }
            } else {
                decisionButton("Approve", "checkmark", .approved, tint: .green) {
                    await model.decide(request, item: item, status: .approved)
                    onDecided()
                }
            }
            decisionButton("Changes", "pencil", .changesRequested, tint: .orange) {
                askChanges()
            }
            decisionButton("Reject", "xmark", .rejected, tint: .red) {
                await model.decide(request, item: item, status: .rejected)
                onDecided()
            }
            if item.status != .pending {
                Menu {
                    Button("Reset to pending", systemImage: "arrow.uturn.backward") {
                        Task { await model.decide(request, item: item, status: .pending) }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
            }
        }
        .disabled(model.isSaving)
    }

    /// Choose this option: approve it and reject the group's others, whatever they were.
    private func pickThis() async {
        await model.pick(request, item: item)
    }

    /// Changes says what to change: the message sheet first, then the decision with it.
    private func askChanges() {
        let request = request, item = item
        askingChanges = ReviewCommentRequest(
            purpose: .changes(files: 1), subject: item.id,
            suggestions: request.commentSuggestions(excluding: item),
            send: { text in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Task {
                    if await model.decide(request, item: item, status: .changesRequested, comment: text) { onDecided() }
                }
            })
    }

    private func decisionButton(
        _ title: String, _ symbol: String, _ status: ReviewStatus, tint: Color,
        action: @escaping () async -> Void
    ) -> some View {
        let selected = item.status == status
        return Button { Task { await action() } } label: {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(selected ? tint : tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func startAnnotating() async {
        isPreparingAnnotation = true
        defer { isPreparingAnnotation = false }
        guard let data = await model.assetData(request, file: item.file) else { return }
        let ext = (item.file as NSString).pathExtension.lowercased()
        annotating = SharedImage(data: data, fileExtension: ext == "png" ? "png" : "jpg", thumbnail: nil)
        showsAnnotator = true
    }

    private func sendAnnotations(_ image: SharedImage) {
        let file = image.attachment()
        let lines = image.annotations.enumerated().map { index, annotation -> String in
            let comment = annotation.comment.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(index + 1). \(comment.isEmpty ? "(marked, no comment)" : comment)"
        }
        Task { await model.annotate(request, item: item, image: file.data, fileExtension: file.fileExtension, text: lines.joined(separator: "\n")) }
    }
}

struct StatusChip: View {
    let status: ReviewStatus

    var body: some View {
        Text(status.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .pending: return .secondary
        case .approved: return .green
        case .rejected: return .red
        case .changesRequested: return .orange
        }
    }
}

// MARK: - Asset viewers

/// Renders an item by kind: image, 3D model (Quick Look / AR), audio, video, animation.
struct ReviewAssetView: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    let item: ReviewItem
    /// Tapping the picture opens the full-screen viewer; without it, the picture alone.
    var onEnlarge: (() -> Void)?
    @State private var quickLook: QuickLookItem?
    @State private var isPreparing = false
    @State private var enlarged = false

    var body: some View {
        content
            .overlay { if isPreparing { ProgressView() } }
            .quickLook(item: $quickLook)
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .image:
            ReviewImage(request: request, file: item.file)
                .contentShape(Rectangle())
                .onTapGesture { if let onEnlarge { onEnlarge() } else { enlarged = true } }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Enlarge \(item.id)")
                .accessibilityIdentifier("reviewAssetImage")
                .fullScreenCover(isPresented: $enlarged) {
                    ImageViewer(request: request, file: item.file).environment(model)
                }
        case .model:
            ZStack(alignment: .bottomTrailing) {
                if let preview = item.preview {
                    ReviewImage(request: request, file: preview)
                } else {
                    Image(systemName: "cube.transparent").font(.system(size: 64)).foregroundStyle(.tertiary)
                }
                Button { Task { await openQuickLook(item.file) } } label: {
                    Label("View in 3D", systemImage: "arkit")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .audio:
            AudioPlayerView(url: model.streamURL(request, file: item.file), fallback: { await model.localAssetURL(request, file: item.file) })
        case .video:
            VideoAssetView(url: model.streamURL(request, file: item.file), fallback: { await model.localAssetURL(request, file: item.file) })
        case .animation:
            AnimationAssetView(request: request, item: item)
        case .other:
            VStack(spacing: 12) {
                Image(systemName: "doc").font(.system(size: 48)).foregroundStyle(.tertiary)
                Button("Open \((item.file as NSString).lastPathComponent)") { Task { await openQuickLook(item.file) } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func openQuickLook(_ file: String) async {
        isPreparing = true
        defer { isPreparing = false }
        quickLook = await model.localAssetURL(request, file: file).map(QuickLookItem.init(url:))
    }
}

/// An image on its own, full screen: pinch or double-tap to zoom, swipe down (or tap the
/// cross) to close.
private struct ImageViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ReviewRequest
    let file: String
    @State private var image: UIImage?
    @State private var failed = false
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    /// How far the picture has been pulled down towards closing, 0...1.
    private var pull: CGFloat { scale > 1 ? 0 : min(1, abs(offset.height) / 300) }

    var body: some View {
        ZStack {
            Color.black.opacity(Double(1 - pull * 0.6)).ignoresSafeArea()
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { scale = max(1, min(6, settledScale * $0.magnification)) }
                            .onEnded { _ in
                                settledScale = scale
                                if scale == 1 { withAnimation { offset = .zero }; settledOffset = .zero }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                // Zoomed in, a drag moves the picture; otherwise it pulls it away.
                                offset = scale > 1
                                    ? CGSize(width: settledOffset.width + value.translation.width, height: settledOffset.height + value.translation.height)
                                    : CGSize(width: 0, height: value.translation.height)
                            }
                            .onEnded { value in
                                if scale > 1 {
                                    settledOffset = offset
                                } else if abs(value.translation.height) > 110 || abs(value.predictedEndTranslation.height) > 500 {
                                    dismiss()
                                } else {
                                    withAnimation(.spring(duration: 0.3)) { offset = .zero }
                                }
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation {
                            scale = scale > 1 ? 1 : 2.5
                            settledScale = scale
                            offset = .zero
                            settledOffset = .zero
                        }
                    }
                    .accessibilityIdentifier("reviewImageViewer")
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark").font(.system(size: 44)).foregroundStyle(.gray)
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.22), in: Circle())
            }
            .padding(16)
            .opacity(Double(1 - pull))
            .accessibilityLabel("Close")
            .accessibilityIdentifier("reviewImageClose")
        }
        .statusBarHidden()
        .task {
            guard let data = await model.assetData(request, file: file),
                  let loaded = await ReviewImageDecoder.image(from: data, maxPixel: 4096) else {
                failed = true
                return
            }
            image = loaded
        }
    }
}

struct QuickLookItem: Identifiable {
    let url: URL
    /// Set when the item names a file of a review request instead of a local file.
    var file: String?
    var id: String { file ?? url.absoluteString }

    init(url: URL) { self.url = url }
    init(file: String) { self.url = URL(fileURLWithPath: "/"); self.file = file }
}

private struct AudioPlayerView: View {
    let url: URL?
    let fallback: () async -> URL?
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var duration: Double = 0

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform").font(.system(size: 56)).foregroundStyle(.tint)
            Button {
                guard let player else { return }
                if isPlaying { player.pause() } else {
                    if progress >= duration, duration > 0 { player.seek(to: .zero) }
                    ReviewAudio.prepare()
                    player.play()
                }
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 52))
            }
            .disabled(player == nil)
            if duration > 0 {
                ProgressView(value: min(progress, duration), total: duration).padding(.horizontal, 32)
                Text("\(ReviewFormat.time(progress)) / \(ReviewFormat.time(duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            let resolved: URL?
            if let url { resolved = url } else { resolved = await fallback() }
            guard let resolved else { return }
            let player = AVPlayer(url: resolved)
            self.player = player
            if let seconds = try? await player.currentItem?.asset.load(.duration).seconds, seconds.isFinite {
                duration = seconds
            }
            while !Task.isCancelled {
                progress = player.currentTime().seconds
                if isPlaying, duration > 0, progress >= duration - 0.05 { isPlaying = false }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        .onDisappear { player?.pause() }
    }
}

private struct VideoAssetView: View {
    let url: URL?
    let fallback: () async -> URL?
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player { VideoPlayer(player: player) } else { ProgressView() }
        }
        .task {
            let resolved: URL?
            if let url { resolved = url } else { resolved = await fallback() }
            if let resolved {
                ReviewAudio.prepare()
                player = AVPlayer(url: resolved)
            }
        }
        .onDisappear { player?.pause() }
    }
}

/// Sound in a review is the thing being reviewed, so it plays with the ring switch on
/// silent too. Without this the app has the system's default audio session, which the
/// silent switch mutes: the player runs and nothing is heard.
enum ReviewAudio {
    static func prepare() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("Review audio: could not start the audio session: \(error)")
        }
    }
}

/// A GIF, or a horizontal sprite sheet played back from `frames` + `fps`.
private struct AnimationAssetView: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    let item: ReviewItem
    @State private var frames: [UIImage] = []
    @State private var frameDuration: Double = 1.0 / 12

    var body: some View {
        Group {
            if frames.isEmpty {
                ProgressView()
            } else {
                TimelineView(.animation(minimumInterval: frameDuration)) { context in
                    let index = Int(context.date.timeIntervalSinceReferenceDate / frameDuration) % frames.count
                    Image(uiImage: frames[index]).resizable().interpolation(.none).scaledToFit()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            guard let data = await model.assetData(request, file: item.file) else { return }
            if let count = item.frames, count > 1, let sheet = UIImage(data: data)?.cgImage {
                let width = sheet.width / count
                frames = (0..<count).compactMap { i in
                    sheet.cropping(to: CGRect(x: i * width, y: 0, width: width, height: sheet.height)).map { UIImage(cgImage: $0) }
                }
                frameDuration = 1.0 / (item.fps ?? 12)
            } else if let source = CGImageSourceCreateWithData(data as CFData, nil) {
                let count = CGImageSourceGetCount(source)
                frames = (0..<count).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil).map { UIImage(cgImage: $0) } }
                if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                   let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any],
                   let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] ?? gif[kCGImagePropertyGIFDelayTime]) as? Double, delay > 0 {
                    frameDuration = delay
                } else if let fps = item.fps {
                    frameDuration = 1.0 / fps
                }
            }
        }
    }
}

/// Quick Look for a local file; USDZ gets the AR / object viewer for free.
///
/// Presented by UIKit, full screen, from an invisible anchor. Hosting `QLPreviewController`
/// inside a SwiftUI sheet leaves its own close button without anything to dismiss, and the
/// sheet's swipe-down goes to the 3D object instead, so the viewer could not be closed.
private struct QuickLookPresenter: UIViewControllerRepresentable {
    @Binding var item: QuickLookItem?

    func makeCoordinator() -> Coordinator { Coordinator(item: $item) }

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ anchor: UIViewController, context: Context) {
        guard let item, context.coordinator.url != item.url, anchor.presentedViewController == nil,
              anchor.view.window != nil else { return }
        context.coordinator.url = item.url
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.delegate = context.coordinator
        // In a navigation controller with our own Done: presented bare, Quick Look can
        // come up without any way to close it.
        let coordinator = context.coordinator
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak anchor] _ in
                anchor?.dismiss(animated: true) { coordinator.closed() }
            })
        let navigation = UINavigationController(rootViewController: preview)
        navigation.modalPresentationStyle = .fullScreen
        anchor.present(navigation, animated: true)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        @Binding var item: QuickLookItem?
        var url: URL?

        init(item: Binding<QuickLookItem?>) { _item = item }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { url == nil ? 0 : 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            (url ?? URL(fileURLWithPath: "/")) as NSURL
        }
        func previewControllerDidDismiss(_ controller: QLPreviewController) { closed() }

        func closed() {
            url = nil
            item = nil
        }
    }
}

extension View {
    /// Show a local file in Quick Look while `item` is set.
    func quickLook(item: Binding<QuickLookItem?>) -> some View {
        background(QuickLookPresenter(item: item).frame(width: 0, height: 0))
    }
}

enum ReviewFormat {
    static func relative(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return iso }
        if abs(date.timeIntervalSinceNow) < 60 { return "just now" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
