import AVKit
import GitKanbanKit
import GitKittieKit
import ImageIO
import QuickLook
import SwiftUI
import UIKit

// Asset review. Shown only when the open board's project has review requests (its
// effective `review_path` folder exists and holds `<request>/review.md` folders).
// Decisions and comments are written back into `review.md` through the board source.

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
                NavigationLink(value: request.folder) {
                    ReviewRequestRow(request: request)
                }
            }
        }
        .navigationTitle(cardID.map { "Reviews · \($0)" } ?? "Reviews")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: String.self) { folder in
            ReviewDetailView(folder: folder)
        }
        .refreshable { await model.loadReviews() }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
    }
}

private struct ReviewRequestRow: View {
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
        if s.pending > 0 { parts.append("\(s.pending) pending") }
        if s.approved > 0 { parts.append("\(s.approved) approved") }
        if s.changesRequested > 0 { parts.append("\(s.changesRequested) changes") }
        if s.rejected > 0 { parts.append("\(s.rejected) rejected") }
        if parts.isEmpty { parts.append("\(s.total) item\(s.total == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// One request: its question and notes, then each group of items side by side.
struct ReviewDetailView: View {
    @Environment(AppModel.self) private var model
    let folder: String

    private var request: ReviewRequest? { model.reviews.first { $0.folder == folder } }

    var body: some View {
        Group {
            if let request {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header(request)
                        ForEach(request.groups) { group in
                            ReviewGroupView(request: request, group: group)
                        }
                    }
                    .padding()
                }
                .navigationTitle(request.title)
            } else {
                ContentUnavailableView("Review not found", systemImage: "questionmark.folder")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.loadReviews() }
        .overlay(alignment: .bottom) {
            if let error = model.errorMessage {
                Text(error).font(.callout).padding(10)
                    .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    .padding()
            }
        }
    }

    @ViewBuilder private func header(_ request: ReviewRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let question = request.question {
                Text(question).font(.title3.weight(.semibold))
            }
            HStack(spacing: 6) {
                if let card = request.card { Text(card) }
                if let by = request.requestedBy { Text("· asked by \(by)") }
                if let at = request.requestedAt { Text("· \(ReviewFormat.relative(at))") }
            }
            .font(.caption).foregroundStyle(.secondary)
            let notes = request.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !notes.isEmpty {
                Text(notes).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// A group of variants (pick one) or a single item.
private struct ReviewGroupView: View {
    let request: ReviewRequest
    let group: ReviewGroup
    @State private var selection: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let name = group.name {
                HStack {
                    Text(name.capitalized).font(.headline)
                    if group.pickOne { Text("Pick one").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if group.items.count > 1 {
                        Text("\((group.items.firstIndex { $0.id == selection } ?? 0) + 1) of \(group.items.count)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if group.items.count > 1 {
                TabView(selection: $selection) {
                    ForEach(group.items) { item in
                        ReviewItemView(request: request, item: item, group: group)
                            .tag(item.id)
                            .padding(.bottom, 36)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                .frame(minHeight: 620)
                .onAppear { if selection.isEmpty { selection = group.items.first?.id ?? "" } }
            } else if let item = group.items.first {
                ReviewItemView(request: request, item: item, group: group)
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
        VStack(alignment: .leading, spacing: 12) {
            AssetView(request: request, item: item)
                .frame(maxWidth: .infinity)
                .frame(height: 320)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14))

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.id).font(.subheadline.weight(.semibold))
                    Text(item.file).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                StatusChip(status: item.status)
            }
            if let revises = item.revises {
                Label("Redo of \(revises)", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let note = item.note { Text(note).font(.callout) }
            if let by = item.decidedBy, let at = item.decidedAt {
                Text("\(item.status.title) by \(by), \(ReviewFormat.relative(at))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let shipped = item.shippedTo {
                Label("Shipped to \(shipped)", systemImage: "shippingbox").font(.caption).foregroundStyle(.secondary)
            }

            decisionButtons

            if !item.comments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(item.comments.enumerated()), id: \.offset) { _, comment in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(comment.by) · \(ReviewFormat.relative(comment.at))")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(comment.text).font(.callout)
                        }
                    }
                }
                .padding(.top, 4)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Comment", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composing)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                Button {
                    let text = draft
                    draft = ""
                    composing = false
                    Task { await model.comment(request, item: item, text: text) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSaving)
            }
        }
    }

    private var decisionButtons: some View {
        HStack(spacing: 8) {
            if group.pickOne && group.items.count > 1 {
                decisionButton("Pick this", "checkmark.circle.fill", .approved, tint: .green) {
                    await pickThis()
                }
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
                Menu {
                    Button("Reset to pending", systemImage: "arrow.uturn.backward") {
                        Task { await model.decide(request, item: item, status: .pending) }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
            }
        }
        .disabled(model.isSaving)
    }

    /// Approve this variant and reject the group's other pending variants.
    private func pickThis() async {
        await model.decide(request, item: item, status: .approved)
        for other in group.items where other.id != item.id && other.status == .pending {
            if let fresh = model.reviews.first(where: { $0.folder == request.folder }) {
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
                .padding(.vertical, 8)
                .background(tint.opacity(selected ? 0.22 : 0.08), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(selected ? tint : .primary)
        }
        .buttonStyle(.plain)
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

    var body: some View {
        content
            .overlay { if isPreparing { ProgressView() } }
            .quickLook(item: $quickLook)
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .image:
            RemoteImage(request: request, file: item.file)
                .onTapGesture { Task { await openQuickLook(item.file) } }
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

struct QuickLookItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// An image loaded through the board source (works for local folders, the folder server
/// and provider repos alike).
private struct RemoteImage: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    let file: String
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
        .task(id: "\(request.folder)/\(file)") {
            guard let data = await model.assetData(request, file: file), let loaded = UIImage(data: data) else {
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
        VStack(spacing: 16) {
            Image(systemName: "waveform").font(.system(size: 56)).foregroundStyle(.tint)
            Button {
                guard let player else { return }
                if isPlaying { player.pause() } else {
                    if progress >= duration, duration > 0 { player.seek(to: .zero) }
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
        preview.modalPresentationStyle = .fullScreen
        anchor.present(preview, animated: true)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        @Binding var item: QuickLookItem?
        var url: URL?

        init(item: Binding<QuickLookItem?>) { _item = item }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { url == nil ? 0 : 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            (url ?? URL(fileURLWithPath: "/")) as NSURL
        }
        func previewControllerDidDismiss(_ controller: QLPreviewController) {
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
