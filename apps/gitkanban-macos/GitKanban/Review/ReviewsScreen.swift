import AVKit
import GitKanbanKit
import GitKittieKit
import ImageIO
import QuickLook
import SwiftUI

// Asset review on the Mac. A board has review requests when its review folder (its
// `review_path`, or `review/` inside the board) holds `<request>/review.md` folders.
// This screen shows every board's requests at once: the list on the left, the chosen
// request on the right, and "Next Waiting" to work through them. Questions read as a form
// at the top of a request; items follow. Decisions, answers and comments are written back
// into `review.md` through the board's source.

struct ReviewsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var selected: ReviewRef?
    @State private var showDecided = false
    /// The message sheet a request's menu opens: Changes on every waiting file (which needs
    /// a message) or a comment on every file.
    @State private var commentSheet: ReviewCommentRequest?
    /// The request about to be removed, once confirmed.
    @State private var removing: ReviewRequest?

    private var listed: [BoardReviews] {
        model.reviewInbox.compactMap { board in
            var board = board
            // A request stays listed while it is open here, also once it is fully decided.
            if !showDecided { board.requests = board.requests.filter { $0.summary.pending > 0 || $0.ref == selected } }
            return board.requests.isEmpty ? nil : board
        }
    }

    /// Where the screen starts: the first waiting request of the board it was opened
    /// from (else that board's first request), or the first waiting request anywhere.
    private var startingRequest: ReviewRef? {
        if let focus = model.reviewsFocusBoard, let board = model.reviewInbox.first(where: { $0.id == focus }) {
            return (board.open.first ?? board.requests.first)?.ref
        }
        return model.openReviewRequests.first?.ref
    }

    /// The next request with something waiting, after the selected one (wrapping round).
    private var nextWaiting: ReviewRef? {
        let open = model.openReviewRequests.map(\.ref)
        guard !open.isEmpty else { return nil }
        let all = model.reviewInbox.flatMap(\.requests).map(\.ref)
        guard let selected, let position = all.firstIndex(of: selected) else { return open.first }
        let after = all[(position + 1)...] + all[..<position]
        return after.first { open.contains($0) }
    }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 300)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Reviews")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button { Task { await model.loadReviewInbox() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .disabled(model.isLoadingReviewInbox)
                    .help("Look for new review requests")
            }
            ToolbarItem {
                Button { selected = nextWaiting } label: { Label("Next Waiting", systemImage: "forward.end.fill") }
                    .disabled(nextWaiting == nil)
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .help("Go to the next request with something waiting")
            }
        }
        .task {
            if !model.hasLoadedReviewInbox { await model.loadReviewInbox() }
            if selected == nil { selected = startingRequest }
        }
        .onChange(of: model.reviewInbox) { _, _ in
            if selected == nil { selected = startingRequest }
        }
        .onChange(of: model.reviewsFocusBoard) { _, _ in selected = startingRequest }
        .sheet(item: $commentSheet) { ReviewCommentSheet(request: $0) }
        .confirmationDialog("Remove “\(removing?.title ?? "")”?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove Request", role: .destructive) {
                if let request = removing {
                    if selected == request.ref { selected = nil }
                    Task { await model.removeReview(request) }
                }
                removing = nil
            }
        } message: {
            Text(removing.map { $0.items.isEmpty ? "The request is deleted from the board." : "The request and its \($0.items.count) files are deleted from the board." } ?? ""
                 + " Your answers go with it; git keeps the history.")
        }
    }

    /// What can be done with a whole request, from a right-click on it. Deciding at once is
    /// for files only: each question needs its own answer, so they are left out.
    @ViewBuilder private func requestMenu(_ request: ReviewRequest) -> some View {
        let s = request.summary
        let waiting = s.pendingItems
        if s.items > 0 {
            Button("Approve All Waiting Files (\(waiting))", systemImage: "checkmark") { Task { await model.decideAll(request, status: .approved) } }
                .disabled(waiting == 0)
            Button("Ask Changes on All Waiting Files…", systemImage: "pencil") {
                commentSheet = ReviewCommentRequest(
                    purpose: .changes(files: waiting), subject: request.title, suggestions: request.commentSuggestions(),
                    send: { text in Task { await model.decideAll(request, status: .changesRequested, comment: text) } })
            }
                .disabled(waiting == 0)
            Button("Reject All Waiting Files", systemImage: "xmark") { Task { await model.decideAll(request, status: .rejected) } }
                .disabled(waiting == 0)
            Divider()
            Button("Comment on All Files…", systemImage: "text.bubble") {
                commentSheet = ReviewCommentRequest(
                    purpose: .comment(files: s.items), subject: request.title, suggestions: request.commentSuggestions(),
                    send: { text in Task { await model.commentAll(request, text: text) } })
            }
            Divider()
        }
        if s.unanswered > 0 {
            Text("\(s.unanswered) question\(s.unanswered == 1 ? "" : "s") to answer in the request")
            Divider()
        }
        ReviewLinkButtons(request: request, file: nil)
        Divider()
        Button("Remove Request…", systemImage: "trash", role: .destructive) { removing = request }
    }

    private var subtitle: String {
        let waiting = model.pendingReviewTotal
        if model.isLoadingReviewInbox, !model.hasLoadedReviewInbox { return "Looking for reviews…" }
        return waiting == 0 ? "Nothing is waiting" : "\(waiting) waiting"
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selected) {
                ForEach(listed) { board in
                    Section {
                        ForEach(board.requests) { request in
                            ReviewRequestRow(request: request).tag(request.ref)
                                .contextMenu { requestMenu(request) }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: board.icon ?? BoardAppearance.defaultIcon)
                                .foregroundStyle(Color(boardColor: board.color))
                            Text(board.boardName)
                            Spacer()
                            if board.pending > 0 { Text("\(board.pending)").monospacedDigit().foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay {
                if listed.isEmpty {
                    if model.isLoadingReviewInbox {
                        ProgressView("Looking for reviews")
                    } else {
                        ContentUnavailableView(
                            model.hasReviews ? "Nothing is waiting" : "No review requests",
                            systemImage: model.hasReviews ? "checkmark.seal.fill" : "checkmark.seal",
                            description: Text(model.hasReviews
                                              ? "Every request on your boards is decided."
                                              : "Agents haven't asked for a review on any of your boards."))
                    }
                }
            }
            Divider()
            Toggle("Show decided requests", isOn: $showDecided)
                .toggleStyle(.checkbox).font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    @ViewBuilder private var detail: some View {
        if let selected, model.reviewRequest(selected) != nil {
            ReviewDetailView(ref: selected, next: nextWaiting.map { next in { self.selected = next } })
                .id(selected)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal").font(.system(size: 44)).foregroundStyle(.tertiary)
                Text(model.pendingReviewTotal > 0 ? "Choose a request" : "Nothing is waiting for you").font(.title3.weight(.semibold))
                if let error = model.errorMessage { Text(error).foregroundStyle(.red).font(.callout) }
            }
        }
    }
}

private struct ReviewRequestRow: View {
    let request: ReviewRequest

    var body: some View {
        let s = request.summary
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(request.title).font(.callout.weight(.medium)).lineLimit(2)
                Spacer(minLength: 6)
                if request.problem != nil {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                        .help("This request's review.md can't be read")
                } else if s.pending > 0 {
                    Text("\(s.pending)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                        .help("\(s.waitingDescription) waiting for you")
                } else {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                }
            }
            Text(summaryLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var summaryLine: String {
        let s = request.summary
        var parts: [String] = []
        if let card = request.card { parts.append(card) }
        if request.problem != nil { parts.append("can't be read"); return parts.joined(separator: " · ") }
        if s.pendingItems > 0, s.approved + s.changesRequested + s.rejected > 0 { parts.append("\(s.pendingItems) waiting") }
        if s.approved > 0 { parts.append("\(s.approved) approved") }
        if s.changesRequested > 0 { parts.append("\(s.changesRequested) changes") }
        if s.rejected > 0 { parts.append("\(s.rejected) rejected") }
        if s.items > 0, s.approved + s.changesRequested + s.rejected == 0 { parts.append("\(s.items) file\(s.items == 1 ? "" : "s")") }
        if let questions = s.questionsDescription { parts.append(questions) }
        return parts.joined(separator: " · ")
    }
}

/// One request: its question, counts and notes, then each group of items side by side.
///
/// The notes and each group's cards are lazy (a stack and a grid), so a request of hundreds
/// of files lays out only what is on screen. The cards are kept cheap to make: see
/// `ReviewItemView`.
private struct ReviewDetailView: View {
    @Environment(AppModel.self) private var model
    let ref: ReviewRef
    /// Goes to the next request with something waiting; `nil` when there is none.
    let next: (() -> Void)?
    /// Which entries show: what waits, what is answered, or everything. Remembered between
    /// requests and launches.
    @AppStorage("reviewsFilter") private var filter: ReviewFilter = .waiting
    /// What the filter hides, fixed when the request opens (or the filter changes), so a
    /// file you just decided stays where it is instead of vanishing under the pointer.
    @State private var hidden: (items: Set<String>, questions: Set<String>) = ([], [])
    /// Files chosen to act on at once: ⌘A, the checkbox, or a click with ⌘ or ⇧.
    @State private var selection: Set<String> = []
    /// Where a ⇧-click range starts: the file last clicked without ⇧.
    @State private var anchor: String?
    /// The message sheet for the selection: Changes (which needs a message) or a comment.
    @State private var selectionSheet: ReviewCommentRequest?
    /// Groups whose answered files are folded away, so what waits is all that shows.
    @State private var foldedGroups: Set<String> = []
    /// The entry last worked on or jumped to: "Next Waiting" goes on from there.
    @State private var current: String?
    @State private var notesExpanded = false

    var body: some View {
        if let request = model.reviewRequest(ref) {
            let groups = request.groups.compactMap { group -> ReviewGroup? in
                var shown = group
                shown.items = group.items.filter { !hidden.items.contains($0.id) }
                return shown.items.isEmpty ? nil : shown
            }
            let questions = request.questions.filter { !hidden.questions.contains($0.id) }
            let shownIDs = groups.flatMap { $0.items.map(\.id) }
            let entries = questions.map(ReviewEntry.question) + groups.flatMap { $0.items.map(ReviewEntry.item) }
            let notes = ReviewNotes.blocks(request)
            let preview = ReviewNotes.previewCount(notes)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header(request).padding(.bottom, 18)
                        if let problem = request.problem { problemBox(problem).padding(.bottom, 22) }
                        if !notes.isEmpty {
                            notesSection(notes, preview: preview)
                        }
                        ForEach(questions) { question in
                            ReviewQuestionRow(request: request, question: question, worked: { current = "question:\(question.id)" })
                                .frame(maxWidth: 680, alignment: .leading)
                                .padding(.bottom, 36)
                                .id("question:\(question.id)")
                        }
                        ForEach(groups) { group in
                            let folded = foldedGroups.contains(group.id)
                            let answeredHere = group.items.filter { $0.status != .pending }.count
                            VStack(alignment: .leading, spacing: 10) {
                                if let name = group.name {
                                    groupHeader(request, group: group, name: name, folded: folded, answeredHere: answeredHere)
                                }
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 18, alignment: .top)],
                                          alignment: .leading, spacing: 18) {
                                    // Folded: only the files that still wait.
                                    ForEach(folded ? group.items.filter { $0.status == .pending } : group.items) { item in
                                        ReviewItemView(request: request, item: item, group: group,
                                                       isSelected: selection.contains(item.id),
                                                       select: { mode in select(item.id, mode, shown: shownIDs) },
                                                       worked: { current = "item:\(item.id)" })
                                            .id("item:\(item.id)")
                                    }
                                }
                            }
                            .padding(.bottom, 26)
                        }
                        if entries.isEmpty {
                            emptyState(request).padding(.vertical, 30)
                        }
                        if request.summary.pending == 0, let next {
                            Button { next() } label: { Label("Next Waiting Request", systemImage: "forward.end.fill") }
                                .controlSize(.large).buttonStyle(.borderedProminent)
                                .padding(.top, 8)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .reviewImages(model: model, request: request)
                .toolbar {
                    ToolbarItem {
                        Button {
                            jumpToNextWaiting(entries, proxy: proxy)
                        } label: {
                            let waiting = entries.filter(\.isWaiting).count
                            Label(waiting == 0 ? "Next Waiting File" : "Next Waiting (\(waiting))", systemImage: "arrow.down.to.line")
                        }
                            .labelStyle(.titleAndIcon)
                            .keyboardShortcut("j", modifiers: .command)
                            .disabled(!entries.contains(where: \.isWaiting))
                            .help("Scroll to the next file or question that waits for you (⌘J)")
                            .accessibilityIdentifier("reviewNextWaitingEntry")
                    }
                    ToolbarItem {
                        Picker("Show", selection: $filter) {
                            ForEach(ReviewFilter.allCases) { option in
                                Text("\(option.title) \(option.count(in: request.summary))").tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .help("Show what waits for you, what you answered, or everything")
                        .accessibilityIdentifier("reviewFilter")
                    }
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    ReviewErrorBanner()
                    if !selection.isEmpty { selectionBar(request) }
                }
            }
            .background {
                // ⌘A and Escape for the files. Kept out of sight: they are the keyboard's way in.
                Group {
                    Button("Select All Files") { selectAll(shownIDs) }
                        .keyboardShortcut("a", modifiers: .command)
                    Button("Clear Selection") { selection = []; anchor = nil }
                        .keyboardShortcut(.cancelAction)
                        .disabled(selection.isEmpty)
                }
                .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
            }
            .sheet(item: $selectionSheet) { ReviewCommentSheet(request: $0) }
            .onAppear {
                notesExpanded = notes.count <= preview
                hide(request)
            }
            .onChange(of: filter) { _, _ in hide(request) }
        }
    }

    /// A group's name, how many of its files wait (over the whole request, not only what is
    /// on show) as a tag in the accent, and a way to fold its answered files away.
    private func groupHeader(_ request: ReviewRequest, group: ReviewGroup, name: String, folded: Bool, answeredHere: Int) -> some View {
        let members = request.items.filter { $0.group == name }
        let waiting = members.filter { $0.status == .pending }.count
        return HStack(spacing: 8) {
            Text(name.capitalized).font(.headline)
            if group.pickOne { Text("Pick one").font(.caption).foregroundStyle(.secondary) }
            if waiting > 0 {
                Text("\(waiting) waiting").font(.caption.weight(.bold)).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Theme.accentFill, in: Capsule()).foregroundStyle(.white)
                Text("of \(members.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Label("All \(members.count) answered", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            Spacer()
            if answeredHere > 0 {
                Button(folded ? "Show \(answeredHere) Answered" : "Hide Answered") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if folded { foldedGroups.remove(group.id) } else { foldedGroups.insert(group.id) }
                    }
                }
                .buttonStyle(.link).font(.caption)
                .help(folded ? "Show the files of this group you already answered" : "Show only the files of this group that wait")
            }
        }
    }

    private func hide(_ request: ReviewRequest) {
        hidden = request.hiddenIDs(for: filter)
        // A file that is no longer on show is no longer chosen.
        selection.subtract(hidden.items)
    }

    /// Scroll to the next entry that waits, after the one last worked on.
    private func jumpToNextWaiting(_ entries: [ReviewEntry], proxy: ScrollViewProxy) {
        guard let next = ReviewEntry.nextWaiting(after: current, in: entries) else { return }
        current = next.id
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(next.id, anchor: .top)
        }
    }

    /// How a file was clicked to choose it.
    enum SelectMode { case toggle, extend }

    private func select(_ id: String, _ mode: SelectMode, shown: [String]) {
        current = "item:\(id)"
        switch mode {
        case .toggle:
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        case .extend:
            guard let anchor, let from = shown.firstIndex(of: anchor), let to = shown.firstIndex(of: id) else {
                selection.insert(id)
                self.anchor = id
                return
            }
            selection.formUnion(shown[min(from, to)...max(from, to)])
        }
    }

    /// ⌘A: every file on show. In a text field it selects the text, as it always does.
    private func selectAll(_ shown: [String]) {
        if NSApp.keyWindow?.firstResponder is NSText {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            return
        }
        selection = Set(shown)
        anchor = shown.first
    }

    /// "N selected" and what can be done with them, in one write each.
    private func selectionBar(_ request: ReviewRequest) -> some View {
        let ids = selection
        return HStack(spacing: 10) {
            Text("\(ids.count) selected").font(.callout.weight(.semibold)).monospacedDigit()
                .accessibilityIdentifier("reviewSelectionCount")
            Divider().frame(height: 18)
            Button { decideSelection(request, ids, .approved) } label: { Label("Approve", systemImage: "checkmark") }
                .tint(.green)
            Button { commentOnSelection(request, ids, changes: true) } label: { Label("Ask Changes…", systemImage: "pencil") }
                .tint(.orange)
            Button { decideSelection(request, ids, .rejected) } label: { Label("Reject", systemImage: "xmark") }
                .tint(.red)
            Button { decideSelection(request, ids, .pending) } label: { Label("Back to Waiting", systemImage: "arrow.uturn.backward") }
            Button { commentOnSelection(request, ids, changes: false) } label: { Label("Comment…", systemImage: "text.bubble") }
            Divider().frame(height: 18)
            Button { selection = []; anchor = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Clear the selection (Escape)")
                .accessibilityLabel("Clear Selection")
        }
        .buttonStyle(.bordered)
        .disabled(model.isSaving)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.card, in: Capsule())
        .overlay { Capsule().strokeBorder(Theme.stroke) }
        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        .padding(.bottom, 16)
    }

    private func decideSelection(_ request: ReviewRequest, _ ids: Set<String>, _ status: ReviewStatus) {
        Task { await model.decide(request, itemIDs: ids, status: status) }
    }

    /// One message for every selected file: asking for changes (it needs one) or a comment.
    private func commentOnSelection(_ request: ReviewRequest, _ ids: Set<String>, changes: Bool) {
        selectionSheet = ReviewCommentRequest(
            purpose: changes ? .changes(files: ids.count) : .comment(files: ids.count),
            subject: ids.count == 1 ? ids.first : nil,
            suggestions: request.commentSuggestions(),
            send: { text in
                Task {
                    if changes {
                        await model.decide(request, itemIDs: ids, status: .changesRequested, comment: text)
                    } else {
                        await model.comment(request, itemIDs: ids, text: text)
                    }
                }
            })
    }

    private func header(_ request: ReviewRequest) -> some View {
        let s = request.summary
        let answered = s.total - s.pending
        return VStack(alignment: .leading, spacing: 8) {
            Text(MarkdownPage.inline(request.question ?? request.title)).font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if let card = request.card { Text(card) }
                if let by = request.requestedBy { Text("· asked by \(by)") }
                if let at = request.requestedAt { Text("· \(ReviewFormat.relative(at))") }
            }
            .font(.caption).foregroundStyle(.secondary)
            if s.total > 0 {
                HStack(spacing: 10) {
                    ProgressView(value: Double(answered), total: Double(s.total))
                        .frame(maxWidth: 220)
                        .tint(s.pending == 0 ? .green : .accentColor)
                    Text(s.pending == 0 ? "All \(s.total) answered" : "\(s.pending) waiting · \(answered) of \(s.total) answered")
                        .font(.callout.weight(.medium)).monospacedDigit()
                        .foregroundStyle(s.pending == 0 ? Color.green : Color.primary)
                        .accessibilityIdentifier("reviewAnsweredCount")
                }
                .padding(.top, 4)
            }
        }
    }

    /// The notes: folded to their start when they are long, so the files are not pushed
    /// screens down.
    @ViewBuilder private func notesSection(_ notes: [MarkdownBlocks.Block], preview: Int) -> some View {
        let shown = notesExpanded ? notes.count : preview
        LazyVStack(alignment: .leading, spacing: 14) {
            ReviewNotesRows(blocks: notes[..<shown])
        }
        .padding(.bottom, 14)
        .frame(maxWidth: 820, alignment: .leading)
        if notes.count > preview {
            Button(notesExpanded ? "Fold Notes Up" : "Show All Notes") {
                withAnimation(.easeInOut(duration: 0.2)) { notesExpanded.toggle() }
            }
            .buttonStyle(.link)
            .padding(.bottom, 22)
        } else {
            Spacer().frame(height: 10)
        }
    }

    private func problemBox(_ problem: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text("This request can't be read").font(.body.weight(.semibold))
                Text("Its review.md has frontmatter that is not valid YAML, so its files and questions can't be shown. \(problem) The agent that wrote it has to fix it.")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .padding(14)
        .frame(maxWidth: 680, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func emptyState(_ request: ReviewRequest) -> some View {
        if request.problem == nil {
            VStack(alignment: .leading, spacing: 10) {
                Text(filter == .answered ? "Nothing answered yet" : "Nothing waits in this request")
                    .font(.title3.weight(.semibold))
                Button("Show All") { filter = .all }
            }
        }
    }
}

/// A question of the request, answered in place. Its own view, so a save starting or
/// ending redraws only the questions, not the whole request.
private struct ReviewQuestionRow: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    let question: ReviewQuestion
    let worked: () -> Void

    var body: some View {
        ReviewQuestionView(question: question, isSaving: model.isSaving) { choices, other, comment in
            worked()
            return await model.answer(request, question: question, choices: choices, other: other, comment: comment)
        }
    }
}

/// What went wrong with the last write, over the review. Its own view, so an error coming
/// and going redraws only this.
private struct ReviewErrorBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let error = model.errorMessage {
            Text(error).font(.callout).padding(10)
                .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .padding()
        }
    }
}

/// One asset: viewer, note, decision and comments.
private struct ReviewItemView: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    let item: ReviewItem
    let group: ReviewGroup
    var isSelected = false
    /// Choose the file to act on with others: toggled, or a range up to it (⇧).
    var select: (ReviewDetailView.SelectMode) -> Void = { _ in }
    /// The file was decided or commented on: "Next Waiting" goes on from here.
    var worked: () -> Void = {}
    @State private var draft = ""
    @State private var writing = false
    /// The message sheet Changes opens: asking for changes needs one.
    @State private var changeSheet: ReviewCommentRequest?
    @FocusState private var composing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AssetView(request: request, item: item)
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                // Answered files step back, so the ones that wait stand out in a long request.
                .opacity(item.status == .pending || isSelected ? 1 : 0.55)
                .overlay(alignment: .topLeading) {
                    if item.status == .pending {
                        Label("Waiting", systemImage: "circle.dashed")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.accentFill, in: Capsule())
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }

            HStack(alignment: .firstTextBaseline) {
                // A drawn checkbox rather than an AppKit one: a request shows hundreds of cards,
                // and each AppKit control made while scrolling costs a frame.
                Button { select(.toggle) } label: {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.body)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help("Select to act on several files at once (⌘A selects all)")
                .accessibilityLabel("Select \(item.id)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.id).font(.subheadline.weight(.semibold))
                    Text(item.file).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                StatusChip(status: item.status)
            }
            if let revises = item.revises {
                Label("Redo of \(revises)", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
            }
            if let note = item.note {
                Text(MarkdownPage.inline(note)).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let by = item.decidedBy, let at = item.decidedAt {
                Text("\(item.status.title) by \(by), \(ReviewFormat.relative(at))").font(.caption).foregroundStyle(.secondary)
            }
            if item.handledAt != nil {
                Label("The agent has acted on it", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.secondary)
            }
            if let shipped = item.shippedTo {
                Label("Shipped to \(shipped)", systemImage: "shippingbox").font(.caption).foregroundStyle(.secondary)
            }

            ReviewDecisionButtons(request: request, item: item, group: group, decided: { _ in worked() },
                                  askChanges: askChanges, comment: openComment)

            ForEach(Array(item.comments.enumerated()), id: \.offset) { _, comment in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(comment.by) · \(ReviewFormat.relative(comment.at))").font(.caption).foregroundStyle(.secondary)
                    Text(comment.text).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // The comment field is made when it is wanted (Comment, or Changes): a text field
            // in every card is what made scrolling a long request stall.
            if writing {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Comment", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                        .focused($composing)
                        .onSubmit(send)
                        .onExitCommand { if draft.isEmpty { writing = false } }
                    // What was said on other files of this request, to say again in one click.
                    ReviewCommentSuggestionMenu(suggestions: request.commentSuggestions(excluding: item)) { draft = $0 }
                    ReviewSendButton(isEmpty: draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, send: send)
                }
            }
        }
        .padding(12)
        // Selected: a tinted fill. Otherwise the card takes a faint tint of its decision, so
        // what is answered reads apart from what still waits at a glance.
        .background(background, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        // A click with ⌘ or ⇧ chooses the file, wherever it lands, before anything inside it reacts.
        .highPriorityGesture(TapGesture().modifiers(.command).onEnded { select(.toggle) })
        .highPriorityGesture(TapGesture().modifiers(.shift).onEnded { select(.extend) })
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Button("Approve", systemImage: "checkmark") { decide(.approved) }
                .disabled(item.status == .approved)
            Button("Ask Changes…", systemImage: "pencil") { askChanges() }
                .disabled(item.status == .changesRequested)
            Button("Reject", systemImage: "xmark") { decide(.rejected) }
                .disabled(item.status == .rejected)
            Button("Back to Waiting", systemImage: "arrow.uturn.backward") { decide(.pending) }
                .disabled(item.status == .pending)
            Divider()
            Button("Comment…", systemImage: "text.bubble") { openComment() }
            Divider()
            ReviewLinkButtons(request: request, file: item.file)
        }
        .sheet(item: $changeSheet) { ReviewCommentSheet(request: $0) }
    }

    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.accentColor.opacity(0.22)) }
        if item.status == .pending { return AnyShapeStyle(Theme.card) }
        return AnyShapeStyle(StatusChip.color(item.status).opacity(0.07))
    }

    /// Changes says what to change: the message sheet first, then the decision with it.
    private func askChanges() {
        let request = request, item = item
        changeSheet = ReviewCommentRequest(
            purpose: .changes(files: 1), subject: item.id,
            suggestions: request.commentSuggestions(excluding: item),
            send: { text in
                worked()
                Task { await model.decide(request, item: item, status: .changesRequested, comment: text) }
            })
    }

    private func decide(_ status: ReviewStatus) {
        worked()
        Task { await model.decide(request, item: item, status: status) }
    }

    private func openComment() {
        writing = true
        Task { @MainActor in composing = true }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        writing = false
        worked()
        Task { await model.comment(request, item: item, text: text) }
    }
}

/// The send button of a comment. Its own view: it follows the model's saving state, and a
/// save starting or ending redraws only this, not the whole card and its picture.
private struct ReviewSendButton: View {
    @Environment(AppModel.self) private var model
    let isEmpty: Bool
    let send: () -> Void

    var body: some View {
        Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(isEmpty || model.isSaving)
            .accessibilityLabel("Send comment")
    }
}

/// Approve (or Pick This), Changes, Reject and back to waiting for one file. Its own view
/// for the same reason as `ReviewSendButton`.
private struct ReviewDecisionButtons: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    let item: ReviewItem
    let group: ReviewGroup
    let decided: (ReviewStatus) -> Void
    /// Changes opens the message sheet: it is never sent without one.
    let askChanges: () -> Void
    let comment: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if group.pickOne && group.items.count > 1 {
                decisionButton("Pick This", "checkmark.circle.fill", .approved, tint: .green) { await pickThis() }
            } else {
                decisionButton("Approve", "checkmark", .approved, tint: .green) {
                    await model.decide(request, item: item, status: .approved)
                }
            }
            Button(action: askChanges) {
                decisionLabel("Changes", "pencil", .changesRequested, tint: .orange)
            }
            .buttonStyle(.plain)
            .help("Ask for changes: say what to change")
            decisionButton("Reject", "xmark", .rejected, tint: .red) {
                await model.decide(request, item: item, status: .rejected)
            }
            if item.status != .pending {
                Button {
                    decided(.pending)
                    Task { await model.decide(request, item: item, status: .pending) }
                } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Back to waiting")
            }
            Button(action: comment) {
                Image(systemName: "text.bubble").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Comment on this file")
            .accessibilityLabel("Comment")
        }
        .disabled(model.isSaving)
    }

    /// Approve this variant and reject the group's other pending variants.
    private func pickThis() async {
        await model.decide(request, item: item, status: .approved)
        for other in group.items where other.id != item.id && other.status == .pending {
            if let fresh = model.reviewRequest(request.ref) {
                await model.decide(fresh, item: other, status: .rejected)
            }
        }
    }

    private func decisionButton(
        _ title: String, _ symbol: String, _ status: ReviewStatus, tint: Color,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            decided(status)
            Task { await action() }
        } label: {
            decisionLabel(title, symbol, status, tint: tint)
        }
        .buttonStyle(.plain)
    }

    private func decisionLabel(_ title: String, _ symbol: String, _ status: ReviewStatus, tint: Color) -> some View {
        let selected = item.status == status
        return Label(title, systemImage: symbol)
            .font(.callout.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(tint.opacity(selected ? 0.24 : 0.09), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(selected ? tint : .primary)
            .contentShape(Rectangle())
    }
}

private struct StatusChip: View {
    let status: ReviewStatus

    var body: some View {
        Label(status == .pending ? "Waiting for you" : status.title, systemImage: Self.symbol(status))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Self.color(status).opacity(status == .pending ? 0.16 : 0.15), in: Capsule())
            .foregroundStyle(Self.color(status))
            .accessibilityIdentifier("reviewItemStatus")
    }

    static func symbol(_ status: ReviewStatus) -> String {
        switch status {
        case .pending: return "circle.dashed"
        case .approved: return "checkmark.circle.fill"
        case .rejected: return "xmark.circle.fill"
        case .changesRequested: return "pencil.circle.fill"
        }
    }

    /// Waiting takes the accent: it is what needs you. A decision takes its own colour.
    static func color(_ status: ReviewStatus) -> Color {
        switch status {
        case .pending: return .accentColor
        case .approved: return .green
        case .rejected: return .red
        case .changesRequested: return .orange
        }
    }
}

// MARK: - Asset viewers

/// Renders an item by kind: image, 3D model (Quick Look), audio, video, animation.
private struct AssetView: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    let item: ReviewItem
    @State private var quickLook: URL?
    @State private var isPreparing = false

    var body: some View {
        content
            .overlay { if isPreparing { ProgressView() } }
            .quickLookPreview($quickLook)
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .image:
            ReviewImage(request: request, file: item.file, maxPixel: 1200)
                .contentShape(Rectangle())
                .onTapGesture { Task { await openQuickLook(item.file) } }
                .help("Click to enlarge")
        case .model:
            ZStack(alignment: .bottomTrailing) {
                if let preview = item.preview {
                    ReviewImage(request: request, file: preview, maxPixel: 1200)
                } else {
                    Image(systemName: "cube.transparent").font(.system(size: 56)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Button { Task { await openQuickLook(item.file) } } label: { Label("View in 3D", systemImage: "cube") }
                    .padding(10)
            }
        case .audio:
            AudioPlayerView(url: model.streamURL(request, file: item.file), fallback: { await model.localAssetURL(request, file: item.file) })
        case .video:
            VideoAssetView(url: model.streamURL(request, file: item.file), fallback: { await model.localAssetURL(request, file: item.file) })
        case .animation:
            AnimationAssetView(request: request, item: item)
        case .other:
            VStack(spacing: 12) {
                Image(systemName: "doc").font(.system(size: 44)).foregroundStyle(.tertiary)
                Button("Open \((item.file as NSString).lastPathComponent)") { Task { await openQuickLook(item.file) } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func openQuickLook(_ file: String) async {
        isPreparing = true
        defer { isPreparing = false }
        quickLook = await model.localAssetURL(request, file: file)
    }
}

private struct AudioPlayerView: View {
    let url: URL?
    let fallback: () async -> URL?
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var duration: Double = 0

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform").font(.system(size: 48)).foregroundStyle(.tint)
            Button {
                guard let player else { return }
                if isPlaying { player.pause() } else {
                    if progress >= duration, duration > 0 { player.seek(to: .zero) }
                    player.play()
                }
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 44))
            }
            .buttonStyle(.plain)
            .disabled(player == nil)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
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
            if let resolved { player = AVPlayer(url: resolved) }
        }
        .onDisappear { player?.pause() }
    }
}

/// A GIF, or a horizontal sprite sheet played back from `frames` + `fps`.
private struct AnimationAssetView: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    let item: ReviewItem
    @State private var frames: [CGImage] = []
    @State private var frameDuration: Double = 1.0 / 12

    var body: some View {
        Group {
            if frames.isEmpty {
                ProgressView()
            } else {
                TimelineView(.animation(minimumInterval: frameDuration)) { context in
                    let index = Int(context.date.timeIntervalSinceReferenceDate / frameDuration) % frames.count
                    Image(decorative: frames[index], scale: 1).resizable().interpolation(.none).scaledToFit()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            guard let data = await model.assetData(request, file: item.file),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return }
            if let count = item.frames, count > 1, let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                let width = sheet.width / count
                frames = (0..<count).compactMap { sheet.cropping(to: CGRect(x: $0 * width, y: 0, width: width, height: sheet.height)) }
                frameDuration = 1.0 / (item.fps ?? 12)
            } else {
                frames = (0..<CGImageSourceGetCount(source)).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }
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

/// Copy a request's (or one file's) link and path, and open it: shared by the menus.
private struct ReviewLinkButtons: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    let file: String?

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var body: some View {
        let link = model.reviewLink(request, file: file)
        Button(file == nil ? "Copy Link to Request" : "Copy Link to File", systemImage: "link") {
            if let link { copy(link.isFileURL ? link.path : link.absoluteString) }
        }
        .disabled(link == nil)
        Button("Copy Path", systemImage: "doc.on.doc") { copy(model.reviewPath(request, file: file)) }
        if let link {
            Button(link.isFileURL ? "Show in Finder" : "Open in Browser", systemImage: link.isFileURL ? "folder" : "safari") {
                if link.isFileURL { NSWorkspace.shared.activateFileViewerSelecting([link]) } else { NSWorkspace.shared.open(link) }
            }
        }
    }
}
