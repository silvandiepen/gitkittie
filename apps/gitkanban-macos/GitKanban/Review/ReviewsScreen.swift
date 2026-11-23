import AVKit
import GitKanbanKit
import GitKittieKit
import ImageIO
import QuickLook
import SwiftUI

// Asset review on the Mac. A board has review requests when its review folder (its
// `review_path`, or `review/` inside the board) holds `<request>/review.md` folders.
// This screen shows every board's requests at once: the list on the left, the chosen
// request on the right, and "Next Waiting" to work through them. Decisions and comments
// are written back into `review.md` through the board's source.

struct ReviewsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var selected: ReviewRef?
    @State private var showDecided = false
    /// The request a comment is being written for, from its menu.
    @State private var commenting: ReviewRequest?
    @State private var commentText = ""
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
        .alert("Comment on \(commenting?.title ?? "")", isPresented: Binding(get: { commenting != nil }, set: { if !$0 { commenting = nil } })) {
            TextField("Comment", text: $commentText)
            Button("Add to All Items") {
                if let request = commenting { let text = commentText; Task { await model.commentAll(request, text: text) } }
                commenting = nil
            }
            Button("Cancel", role: .cancel) { commenting = nil }
        } message: {
            Text("The comment is added to every item of this request, for the agent to read.")
        }
        .confirmationDialog("Remove “\(removing?.title ?? "")”?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove Request", role: .destructive) {
                if let request = removing {
                    if selected == request.ref { selected = nil }
                    Task { await model.removeReview(request) }
                }
                removing = nil
            }
        } message: {
            Text("The request and its \(removing?.items.count ?? 0) files are deleted from the board. Your answers go with it; git keeps the history.")
        }
    }

    /// What can be done with a whole request, from a right-click on it.
    @ViewBuilder private func requestMenu(_ request: ReviewRequest) -> some View {
        let waiting = request.summary.pending
        Button("Approve All Waiting (\(waiting))", systemImage: "checkmark") { Task { await model.decideAll(request, status: .approved) } }
            .disabled(waiting == 0)
        Button("Ask Changes on All Waiting", systemImage: "pencil") { Task { await model.decideAll(request, status: .changesRequested) } }
            .disabled(waiting == 0)
        Button("Reject All Waiting", systemImage: "xmark") { Task { await model.decideAll(request, status: .rejected) } }
            .disabled(waiting == 0)
        Divider()
        Button("Comment on All…", systemImage: "text.bubble") { commentText = ""; commenting = request }
        Divider()
        ReviewLinkButtons(request: request, file: nil)
        Divider()
        Button("Remove Request…", systemImage: "trash", role: .destructive) { removing = request }
    }

    private var subtitle: String {
        let waiting = model.pendingReviewTotal
        if model.isLoadingReviewInbox, !model.hasLoadedReviewInbox { return "Looking for reviews…" }
        return waiting == 0 ? "Nothing is waiting" : "\(waiting) item\(waiting == 1 ? "" : "s") waiting"
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
                if s.pending > 0 {
                    Text("\(s.pending)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
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
        if s.approved > 0 { parts.append("\(s.approved) approved") }
        if s.changesRequested > 0 { parts.append("\(s.changesRequested) changes") }
        if s.rejected > 0 { parts.append("\(s.rejected) rejected") }
        if parts.isEmpty || (parts.count == 1 && request.card != nil) { parts.append("\(s.total) item\(s.total == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// One request: its question and notes, then each group of items side by side.
private struct ReviewDetailView: View {
    @Environment(AppModel.self) private var model
    let ref: ReviewRef
    /// Goes to the next request with something waiting; `nil` when there is none.
    let next: (() -> Void)?

    var body: some View {
        if let request = model.reviewRequest(ref) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header(request)
                    ForEach(request.groups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            if let name = group.name {
                                HStack(spacing: 8) {
                                    Text(name.capitalized).font(.headline)
                                    if group.pickOne { Text("Pick one").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                                ForEach(group.items) { item in
                                    ReviewItemView(request: request, item: item, group: group)
                                }
                            }
                        }
                    }
                    if request.summary.pending == 0, let next {
                        Button { next() } label: { Label("Next Waiting Request", systemImage: "forward.end.fill") }
                            .controlSize(.large).buttonStyle(.borderedProminent)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay(alignment: .bottom) {
                if let error = model.errorMessage {
                    Text(error).font(.callout).padding(10)
                        .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                        .padding()
                }
            }
        }
    }

    private func header(_ request: ReviewRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(request.question ?? request.title).font(.title2.weight(.semibold))
            HStack(spacing: 6) {
                if let card = request.card { Text(card) }
                if let by = request.requestedBy { Text("· asked by \(by)") }
                if let at = request.requestedAt { Text("· \(ReviewFormat.relative(at))") }
            }
            .font(.caption).foregroundStyle(.secondary)
            let notes = request.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !notes.isEmpty {
                Text(notes).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

/// One asset: viewer, note, decision and comments.
private struct ReviewItemView: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    let item: ReviewItem
    let group: ReviewGroup
    @State private var draft = ""
    @FocusState private var composing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AssetView(request: request, item: item)
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(alignment: .firstTextBaseline) {
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
            if let note = item.note { Text(note).font(.callout).textSelection(.enabled) }
            if let by = item.decidedBy, let at = item.decidedAt {
                Text("\(item.status.title) by \(by), \(ReviewFormat.relative(at))").font(.caption).foregroundStyle(.secondary)
            }
            if let shipped = item.shippedTo {
                Label("Shipped to \(shipped)", systemImage: "shippingbox").font(.caption).foregroundStyle(.secondary)
            }

            decisionButtons

            ForEach(Array(item.comments.enumerated()), id: \.offset) { _, comment in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(comment.by) · \(ReviewFormat.relative(comment.at))").font(.caption).foregroundStyle(.secondary)
                    Text(comment.text).font(.callout).textSelection(.enabled)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Comment", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .focused($composing)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSaving)
                    .accessibilityLabel("Send comment")
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .contextMenu {
            Button("Approve", systemImage: "checkmark") { Task { await model.decide(request, item: item, status: .approved) } }
                .disabled(item.status == .approved)
            Button("Ask Changes", systemImage: "pencil") { Task { await model.decide(request, item: item, status: .changesRequested) } }
                .disabled(item.status == .changesRequested)
            Button("Reject", systemImage: "xmark") { Task { await model.decide(request, item: item, status: .rejected) } }
                .disabled(item.status == .rejected)
            Button("Back to Waiting", systemImage: "arrow.uturn.backward") { Task { await model.decide(request, item: item, status: .pending) } }
                .disabled(item.status == .pending)
            Divider()
            Button("Comment…", systemImage: "text.bubble") { composing = true }
            Divider()
            ReviewLinkButtons(request: request, file: item.file)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await model.comment(request, item: item, text: text) }
    }

    private var decisionButtons: some View {
        HStack(spacing: 8) {
            if group.pickOne && group.items.count > 1 {
                decisionButton("Pick This", "checkmark.circle.fill", .approved, tint: .green) { await pickThis() }
            } else {
                decisionButton("Approve", "checkmark", .approved, tint: .green) {
                    await model.decide(request, item: item, status: .approved)
                }
            }
            decisionButton("Changes", "pencil", .changesRequested, tint: .orange) {
                await model.decide(request, item: item, status: .changesRequested)
                composing = true
            }
            decisionButton("Reject", "xmark", .rejected, tint: .red) {
                await model.decide(request, item: item, status: .rejected)
            }
            if item.status != .pending {
                Button { Task { await model.decide(request, item: item, status: .pending) } } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Reset to pending")
            }
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
        let selected = item.status == status
        return Button { Task { await action() } } label: {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(tint.opacity(selected ? 0.24 : 0.09), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(selected ? tint : .primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct StatusChip: View {
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
            RemoteImage(request: request, file: item.file)
                .contentShape(Rectangle())
                .onTapGesture { Task { await openQuickLook(item.file) } }
                .help("Click to enlarge")
        case .model:
            ZStack(alignment: .bottomTrailing) {
                if let preview = item.preview {
                    RemoteImage(request: request, file: preview)
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

/// An image loaded through the board's source (folders, the folder server and provider
/// repositories alike).
private struct RemoteImage: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    let file: String
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark").font(.system(size: 36)).foregroundStyle(.tertiary)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(request.ref.id)/\(file)") {
            guard let data = await model.assetData(request, file: file), let loaded = NSImage(data: data) else {
                failed = true
                return
            }
            image = loaded
        }
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
