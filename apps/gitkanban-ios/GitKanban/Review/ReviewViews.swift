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
        .navigationTitle(cardID.map { "Reviews · \($0)" } ?? "Reviews")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: ReviewRef.self) { ref in
            ReviewDetailView(ref: ref)
        }
        .refreshable { await model.loadReviews() }
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
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert("Comment on All Files", isPresented: Binding(get: { commenting != nil }, set: { if !$0 { commenting = nil } }),
                   presenting: commenting) { request in
                TextField("Comment", text: $text)
                Button("Add to All Files") {
                    let comment = text
                    text = ""
                    Task { await model.commentAll(request, text: comment) }
                }
                Button("Cancel", role: .cancel) { text = "" }
            } message: { request in
                Text("The comment is added to all \(request.summary.items) files of “\(request.title)”, for the agent to read.")
            }
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
            if let question = request.question {
                Text(question).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(summaryLine(request)).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func summaryLine(_ request: ReviewRequest) -> String {
        let s = request.summary
        var parts: [String] = []
        if let card = request.card { parts.append(card) }
        if s.pendingItems > 0 { parts.append("\(s.pendingItems) pending") }
        if s.approved > 0 { parts.append("\(s.approved) approved") }
        if s.changesRequested > 0 { parts.append("\(s.changesRequested) changes") }
        if s.rejected > 0 { parts.append("\(s.rejected) rejected") }
        if let questions = s.questionsDescription { parts.append(questions) }
        if parts.isEmpty || (parts.count == 1 && request.card != nil) { parts.append("\(s.items) item\(s.items == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// One page of a request: a question to answer or a file to judge.
private enum ReviewPage: Identifiable {
    case question(ReviewQuestion)
    case item(ReviewItem)

    var id: String {
        switch self {
        case .question(let question): return "question:\(question.id)"
        case .item(let item): return "item:\(item.id)"
        }
    }

    /// Still waiting for the reviewer.
    var isWaiting: Bool {
        switch self {
        case .question(let question): return !question.isAnswered
        case .item(let item): return item.status == .pending
        }
    }

    var color: Color {
        switch self {
        case .question(let question): return question.isAnswered ? Theme.accent : .secondary
        case .item(let item): return ReviewColor.status(item.status)
        }
    }

    /// Questions first: they are what the agent is waiting on to go on.
    static func all(_ request: ReviewRequest) -> [ReviewPage] {
        request.questions.map(ReviewPage.question) + request.items.map(ReviewPage.item)
    }

    /// "2 items and 1 question have no answer yet".
    static func noAnswerTitle(_ pages: [ReviewPage]) -> String {
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

    /// The pages on show, fixed when the request opens so an answered slide does not
    /// vanish under your thumb.
    @State private var slideIDs: [String] = []
    @State private var selection = ""
    @State private var showsAnswered = false
    @State private var confirmClose = false
    @State private var commenting: ReviewRequest?
    @State private var removing: ReviewRequest?

    private var request: ReviewRequest? { model.reviewRequest(ref) }

    private func slides(_ request: ReviewRequest) -> [ReviewPage] {
        ReviewPage.all(request).filter { slideIDs.contains($0.id) }
    }

    private func unanswered(_ request: ReviewRequest) -> [ReviewPage] {
        slides(request).filter(\.isWaiting)
    }

    var body: some View {
        Group {
            if let request {
                let pages = slides(request)
                VStack(spacing: 0) {
                    header(request, pages: pages)
                    if pages.isEmpty {
                        ContentUnavailableView("Nothing to review", systemImage: "checkmark.seal")
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
                                                    isNear: abs(index - (pages.firstIndex { $0.id == selection } ?? 0)) <= 1,
                                                    onDecided: { advance(after: page.id) })
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
                .onChange(of: showsAnswered) { _, _ in load(request) }
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
                    Toggle("Show Answered", isOn: $showsAnswered)
                    Button("Reload", systemImage: "arrow.clockwise") { Task { await model.refreshReviews() } }
                    if let request {
                        ReviewRequestCommands(request: request, commenting: $commenting, removing: $removing)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityIdentifier("reviewMoreMenu")
            }
        }
        .reviewRequestPrompts(commenting: $commenting, removing: $removing, onRemoved: { dismiss() })
        .overlay(alignment: .bottom) {
            if let error = model.errorMessage {
                Text(error).font(.callout).padding(10)
                    .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    .padding()
            }
        }
    }

    /// What is on show: the questions and items without an answer, with the other options
    /// of a pick-one group that is still open. A request with nothing waiting shows everything.
    private func load(_ request: ReviewRequest) {
        let all = ReviewPage.all(request)
        let waitingItems = request.items.filter { $0.status == .pending }
        let everything = showsAnswered || !all.contains(where: \.isWaiting)
        let openGroups = Set(waitingItems.compactMap(\.group))
        let shown = everything ? all : all.filter { page in
            switch page {
            case .question(let question): return !question.isAnswered
            case .item(let item): return item.status == .pending || (item.group.map(openGroups.contains) ?? false)
            }
        }
        slideIDs = shown.map(\.id)
        if !slideIDs.contains(selection) {
            selection = shown.first(where: \.isWaiting)?.id ?? shown.first?.id ?? ""
        }
    }

    private func goToUnanswered(_ request: ReviewRequest) {
        if let next = unanswered(request).first { withAnimation { selection = next.id } }
    }

    /// After an answer: on to the next page that has none, when there is one.
    private func advance(after id: String) {
        guard let request = model.reviewRequest(ref) else { return }
        let pages = slides(request)
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        let later = pages[(index + 1)...].first(where: \.isWaiting) ?? pages[..<index].first(where: \.isWaiting)
        if let later { withAnimation { selection = later.id } }
    }

    private func header(_ request: ReviewRequest, pages: [ReviewPage]) -> some View {
        let answered = pages.filter { !$0.isWaiting }.count
        let position = (pages.firstIndex { $0.id == selection } ?? 0) + 1
        return VStack(alignment: .leading, spacing: 8) {
            if let question = request.question {
                Text(question).font(.headline).lineLimit(3)
            }
            // One segment per slide, coloured by its answer; tap to go there.
            HStack(spacing: 3) {
                ForEach(pages) { page in
                    Capsule()
                        .fill(page.color.opacity(page.isWaiting ? 0.3 : 1))
                        .frame(height: page.id == selection ? 7 : 4)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle().inset(by: -8))
                        .onTapGesture { withAnimation { selection = page.id } }
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            HStack {
                Text("\(position) of \(pages.count)").monospacedDigit()
                Spacer()
                Text("\(answered) of \(pages.count) answered").monospacedDigit()
                    .accessibilityIdentifier("reviewAnsweredCount")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal).padding(.top, 8).padding(.bottom, 6)
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
}

/// One item, filling a page: the asset, what was decided, the answer buttons and comments.
private struct ReviewSlide: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    let item: ReviewItem
    /// On screen or next to it: only then is the asset loaded.
    var isNear = true
    let onDecided: () -> Void
    @State private var draft = ""
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
                        if isNear { AssetView(request: request, item: item) } else { Color.clear }
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
                            if let note = item.note { Text(note).font(.callout).foregroundStyle(.secondary) }
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
                                RemoteImage(request: request, file: image, maxPixel: 600)
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
                await model.decide(request, item: item, status: .changesRequested)
                composing = true
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
        await model.decide(request, item: item, status: .approved)
        for other in options where other.id != item.id && other.status != .rejected {
            if let fresh = model.reviewRequest(request.ref) {
                await model.decide(fresh, item: other, status: .rejected)
            }
        }
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
private struct AssetView: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    let item: ReviewItem
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
            RemoteImage(request: request, file: item.file)
                .contentShape(Rectangle())
                .onTapGesture { enlarged = true }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Enlarge \(item.id)")
                .accessibilityIdentifier("reviewAssetImage")
                .fullScreenCover(isPresented: $enlarged) {
                    ImageViewer(request: request, file: item.file).environment(model)
                }
        case .model:
            ZStack(alignment: .bottomTrailing) {
                if let preview = item.preview {
                    RemoteImage(request: request, file: preview)
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

/// An image loaded through the board source (works for local folders, the folder server
/// and provider repos alike).
private struct RemoteImage: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    let file: String
    /// The longest side to decode to, in pixels.
    var maxPixel = 1600
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark").font(.system(size: 40)).foregroundStyle(.tertiary)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(request.ref.id)/\(file)") {
            guard let data = await model.assetData(request, file: file),
                  let loaded = await ReviewImageDecoder.image(from: data, maxPixel: maxPixel) else {
                failed = true
                return
            }
            image = loaded
        }
    }
}

/// Decodes pictures off the main thread and no larger than they are shown: a full-size
/// decode of every image in a request is what runs the app out of memory.
enum ReviewImageDecoder {
    static func image(from data: Data, maxPixel: Int) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
        }.value
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
