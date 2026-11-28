import GitKanbanKit
import GitKittieKit
import SwiftUI
import UIKit

// The full-screen review viewer (GITKITTIE-126): a request's files one per page, edge to edge
// on black, swiped through in the order the review screen shows them (its Waiting / Answered /
// All filter). Pictures zoom with two fingers or a double tap and pan when zoomed; a swipe down
// closes the viewer when not zoomed. Approve, Changes and Reject sit in the thumb zone; after a
// decision the viewer goes on to the next file that waits, says what was done and offers Undo.

/// What opens the viewer: the pages, fixed by the review screen, and the file tapped.
struct ReviewFullScreenStart: Identifiable {
    let id = UUID()
    let pager: ReviewPager
    let itemID: String
}

struct ReviewFullScreenView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let ref: ReviewRef
    let pager: ReviewPager
    @State private var selection: String
    /// How far a swipe down has pulled the page towards closing, 0...1.
    @State private var pull: CGFloat = 0
    /// The bars over the picture are hidden (a single tap on the picture).
    @State private var chromeHidden = false
    @State private var commenting: ReviewCommentRequest?
    @State private var undo: ReviewUndo?
    @State private var undoTimer: Task<Void, Never>?
    @State private var finished = false

    init(ref: ReviewRef, start: ReviewFullScreenStart) {
        self.ref = ref
        pager = start.pager
        _selection = State(initialValue: start.itemID)
    }

    private var request: ReviewRequest? { model.reviewRequest(ref) }

    var body: some View {
        ZStack {
            Color.black.opacity(Double(1 - pull * 0.7)).ignoresSafeArea()
            if let request {
                let items = pager.items(in: request)
                let position = items.firstIndex { $0.id == selection } ?? 0
                TabView(selection: $selection) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        FullScreenPage(
                            request: request, item: item,
                            isNear: abs(index - position) <= 1,
                            onPull: { pull = $0 },
                            onDismiss: { dismiss() },
                            onTap: { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } }
                        )
                        .tag(item.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }
        }
        .overlay(alignment: .top) {
            if let request, !chromeHidden { topBar(request).opacity(Double(1 - pull)) }
        }
        .overlay(alignment: .bottom) {
            if let request, !chromeHidden { bottomBar(request).opacity(Double(1 - pull)) }
        }
        .statusBarHidden()
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reviewFullScreen")
        .sheet(item: $commenting) { request in ReviewCommentSheet(request: request) }
        .onDisappear { undoTimer?.cancel() }
    }

    // MARK: Bars

    private func topBar(_ request: ReviewRequest) -> some View {
        let items = pager.items(in: request)
        let current = items.first { $0.id == selection }
        let waiting = pager.waitingCount(in: request)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(0.16), in: Circle())
                }
                .accessibilityLabel("Close")
                .accessibilityIdentifier("fullScreenClose")
                VStack(alignment: .leading, spacing: 2) {
                    Text(current?.id ?? "")
                        .font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("fullScreenTitle")
                    HStack(spacing: 6) {
                        Text(pager.positionLabel(of: selection, in: request)).monospacedDigit()
                            .accessibilityIdentifier("fullScreenPosition")
                        Text("·")
                        Text(waiting == 0 ? "all answered" : "\(waiting) waiting").monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 8)
                if let current { FullScreenStatus(status: current.status) }
            }
            ReviewProgressStrip(marks: pager.marks(in: request), position: items.firstIndex { $0.id == selection } ?? 0) { index in
                if items.indices.contains(index) { go(to: items[index].id) }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
        .background(LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: .top))
    }

    private func bottomBar(_ request: ReviewRequest) -> some View {
        let current = pager.items(in: request).first { $0.id == selection }
        let next = pager.nextWaiting(after: selection, in: request)
        return VStack(spacing: 10) {
            if let undo {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(ReviewColor.status(undo.status))
                    Text(undo.message).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("Undo") { Task { await takeBack(undo) } }
                        .font(.callout.weight(.semibold))
                        .accessibilityIdentifier("fullScreenUndo")
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.card, in: Capsule())
                .overlay { Capsule().strokeBorder(Theme.stroke) }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .contain)
            } else if finished {
                Label("Nothing else waits in this review", systemImage: "checkmark.seal.fill")
                    .font(.callout.weight(.medium)).foregroundStyle(.green)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.card, in: Capsule())
                    .transition(.opacity)
            }
            if let note = current?.note {
                Text(MarkdownPage.inline(note)).font(.footnote).foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let current {
                HStack(spacing: 10) {
                    decisionButton(current, isChoice(current, in: request) ? "Pick This" : "Approve", "checkmark", .approved, .green, "fullScreenApprove")
                    decisionButton(current, "Changes", "pencil", .changesRequested, .orange, "fullScreenChanges")
                    decisionButton(current, "Reject", "xmark", .rejected, .red, "fullScreenReject")
                }
                .disabled(model.isSaving)
            }
            if let next, next != selection {
                Button { go(to: next) } label: {
                    Label("Next waiting", systemImage: "forward.fill")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.white.opacity(0.14), in: Capsule())
                }
                .accessibilityIdentifier("fullScreenNextWaiting")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
        .background(LinearGradient(colors: [.black.opacity(0), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: .bottom))
        .animation(.easeInOut(duration: 0.2), value: undo?.id)
    }

    private func decisionButton(_ item: ReviewItem, _ title: String, _ symbol: String, _ status: ReviewStatus,
                                _ tint: Color, _ identifier: String) -> some View {
        let selected = item.status == status
        return Button {
            if status.needsComment {
                askChanges(item)
            } else {
                Task { await decide(item, status) }
            }
        } label: {
            Label(title, systemImage: symbol)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(selected ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.22)), in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(selected ? 0 : 0.6), lineWidth: 1) }
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Deciding

    private func isChoice(_ item: ReviewItem, in request: ReviewRequest) -> Bool {
        guard let group = item.group else { return false }
        let members = request.items.filter { $0.group == group }
        return members.count > 1 && members.contains(where: \.pickOne)
    }

    private func askChanges(_ item: ReviewItem) {
        guard let request else { return }
        commenting = ReviewCommentRequest(
            purpose: .changes(files: 1), subject: item.id,
            suggestions: request.commentSuggestions(excluding: item),
            send: { text in Task { await decide(item, .changesRequested, comment: text) } })
    }

    private func decide(_ item: ReviewItem, _ status: ReviewStatus, comment: String? = nil) async {
        guard let before = model.reviewRequest(ref) else { return }
        let written: Bool
        if status == .approved, isChoice(item, in: before) {
            written = await model.pick(before, item: item)
        } else {
            written = await model.decide(before, item: item, status: status, comment: comment)
        }
        guard written, let after = model.reviewRequest(ref) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        offerUndo(ReviewUndo(ref: ref, itemID: item.id, status: status, before: before, after: after))
        if let next = pager.nextWaiting(after: item.id, in: after) {
            go(to: next)
            finished = false
        } else {
            finished = pager.waitingCount(in: after) == 0
        }
    }

    private func offerUndo(_ action: ReviewUndo?) {
        undoTimer?.cancel()
        undo = action
        guard action != nil else { return }
        undoTimer = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { undo = nil }
        }
    }

    private func takeBack(_ action: ReviewUndo) async {
        undoTimer?.cancel()
        undo = nil
        finished = false
        if await model.undo(action) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            go(to: action.itemID)
        }
    }

    private func go(to id: String) {
        if reduceMotion { selection = id } else { withAnimation(.easeInOut(duration: 0.3)) { selection = id } }
    }
}

/// The decision of the file on screen, as plainly as it can be said.
private struct FullScreenStatus: View {
    let status: ReviewStatus

    var body: some View {
        let waiting = status == .pending
        Label(waiting ? "Waiting" : status.title, systemImage: ReviewColor.symbol(status))
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(waiting ? AnyShapeStyle(Theme.accentFill) : AnyShapeStyle(ReviewColor.status(status)), in: Capsule())
            .foregroundStyle(.white)
            .accessibilityIdentifier("fullScreenStatus-\(waiting ? "Waiting" : status.title)")
    }
}

/// One page: the file, filling the screen. Pictures zoom; the other kinds show as on the review
/// screen, readable on black.
private struct FullScreenPage: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    let item: ReviewItem
    let isNear: Bool
    let onPull: (CGFloat) -> Void
    let onDismiss: () -> Void
    let onTap: () -> Void

    var body: some View {
        Group {
            if !isNear {
                Color.clear
            } else {
                switch item.kind {
                case .image:
                    ZoomablePicture(request: request, file: item.file, onPull: onPull, onDismiss: onDismiss, onTap: onTap)
                case .other where ReviewText.isText(item.file):
                    ReviewTextPage(request: request, item: item)
                        .safeAreaPadding(.vertical, 120)
                default:
                    ReviewAssetView(request: request, item: item)
                        .safeAreaPadding(.vertical, 120)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(item.id)
    }
}

// MARK: - Text files

enum ReviewText {
    /// Files shown as text in the viewer rather than as a file to open.
    static func isText(_ file: String) -> Bool {
        ["md", "markdown", "txt", "text", "json", "yaml", "yml", "csv", "log", "swift", "ts", "js", "html", "css", "xml"]
            .contains((file as NSString).pathExtension.lowercased())
    }

    static func isMarkdown(_ file: String) -> Bool {
        ["md", "markdown"].contains((file as NSString).pathExtension.lowercased())
    }
}

/// A text or Markdown file, readable: Markdown drawn, anything else in a monospaced font.
private struct ReviewTextPage: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    let item: ReviewItem
    @State private var text: String?
    @State private var failed = false

    var body: some View {
        ScrollView {
            Group {
                if let text {
                    if ReviewText.isMarkdown(item.file) {
                        MarkdownPage(markdown: text)
                    } else {
                        Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if failed {
                    Label("Can't read \(item.file)", systemImage: "doc.badge.exclamationmark").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .padding(20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 12)
        }
        .foregroundStyle(.white)
        .task {
            guard let data = await model.assetData(request, file: item.file) else { failed = true; return }
            // A review's notes and documents are small; a very large file is cut, not frozen on.
            text = String(decoding: data.prefix(400_000), as: UTF8.self)
        }
    }
}

// MARK: - Progress

/// Every page as a tick: waiting ones bright in the accent, answered ones in a dim tint of their
/// decision, the page on screen taller. Tap or drag along it to go to a page. Drawn in one
/// canvas, so a request of hundreds of files costs no more than one of ten.
struct ReviewProgressStrip: View {
    let marks: [ReviewStatus]
    let position: Int
    let go: (Int) -> Void

    var body: some View {
        Canvas { context, size in
            guard !marks.isEmpty else { return }
            let gap: CGFloat = marks.count > 80 ? 0.5 : (marks.count > 40 ? 1 : 2)
            let width = max(1, (size.width - gap * CGFloat(marks.count - 1)) / CGFloat(marks.count))
            for (index, mark) in marks.enumerated() {
                let x = CGFloat(index) * (width + gap)
                let current = index == position
                let height: CGFloat = current ? size.height : (mark == .pending ? size.height * 0.7 : size.height * 0.4)
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: width, height: height)
                let color: Color = mark == .pending ? Theme.accent : ReviewColor.status(mark).opacity(0.45)
                context.fill(Path(roundedRect: rect, cornerRadius: min(width, height) / 2), with: .color(current ? .white : color))
            }
        }
        .frame(height: 10)
        .contentShape(Rectangle().inset(by: -10))
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in pick(value.location.x) })
        .background(GeometryReader { proxy in Color.clear.preference(key: StripWidthKey.self, value: proxy.size.width) })
        .onPreferenceChange(StripWidthKey.self) { width = $0 }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(marks.filter { $0 == .pending }.count) of \(marks.count) waiting")
        .accessibilityIdentifier("fullScreenProgress")
    }

    @State private var width: CGFloat = 1

    private func pick(_ x: CGFloat) {
        guard !marks.isEmpty, width > 0 else { return }
        let index = Int((x / width) * CGFloat(marks.count))
        let clamped = min(max(index, 0), marks.count - 1)
        if clamped != position { go(clamped) }
    }
}

private struct StripWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Zoom

/// A picture of the request that zooms: two fingers or a double tap, panned when zoomed, a swipe
/// down (when not zoomed) pulls it away to close. UIKit's scroll view does the zooming: it is the
/// one that pans a zoomed picture and still lets the pager take a swipe at the picture's edge.
private struct ZoomablePicture: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    let file: String
    let onPull: (CGFloat) -> Void
    let onDismiss: () -> Void
    let onTap: () -> Void
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                ZoomingImageView(image: image, onPull: onPull, onDismiss: onDismiss, onTap: onTap)
                    .ignoresSafeArea()
                    .accessibilityIdentifier("fullScreenImage")
            } else if failed {
                Label("Can't load \(file)", systemImage: "photo.badge.exclamationmark").foregroundStyle(.gray)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: "\(request.ref.id)/\(file)") {
            if let loaded = await ReviewImageCache.load(model, request, file: file, maxPixel: 4096) {
                image = loaded
            } else {
                failed = true
            }
        }
    }
}

private struct ZoomingImageView: UIViewRepresentable {
    let image: UIImage
    let onPull: (CGFloat) -> Void
    let onDismiss: () -> Void
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.coordinator = context.coordinator
        view.show(image)
        return view
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        context.coordinator.onPull = onPull
        context.coordinator.onDismiss = onDismiss
        context.coordinator.onTap = onTap
        if view.imageView.image !== image { view.show(image) }
    }

    @MainActor
    final class Coordinator {
        var onPull: (CGFloat) -> Void = { _ in }
        var onDismiss: () -> Void = {}
        var onTap: () -> Void = {}
    }
}

/// The scroll view that zooms one picture, centred, with a double tap to zoom in on a spot and
/// out again, and a downward pan that pulls the picture away when it is not zoomed.
private final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let imageView = UIImageView()
    weak var coordinator: ZoomingImageView.Coordinator?
    private lazy var pullGesture = UIPanGestureRecognizer(target: self, action: #selector(pulled(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.require(toFail: doubleTap)
        addGestureRecognizer(tap)
        pullGesture.delegate = self
        addGestureRecognizer(pullGesture)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ image: UIImage) {
        imageView.image = image
        zoomScale = 1
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard zoomScale == 1, let image = imageView.image, bounds.width > 0, bounds.height > 0 else {
            centre()
            return
        }
        // The picture's own frame is the aspect-fit rectangle, so a zoomed picture pans over
        // the picture and not over the black around it.
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        centre()
    }

    private func centre() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centre() }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let scale: CGFloat = 2.5
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }

    @objc private func tapped() { coordinator?.onTap() }

    /// The pull and the scroll view's own pan may both start: at zoom 1 the scroll view has
    /// nothing to scroll, and the pull decides by its direction.
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (gesture === pullGesture && other === panGestureRecognizer) || (other === pullGesture && gesture === panGestureRecognizer)
    }

    // A swipe down, not zoomed: the picture follows the finger and the black fades; let go far
    // enough (or fast enough) and the viewer closes.
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === pullGesture else { return super.gestureRecognizerShouldBegin(gesture) }
        guard zoomScale <= 1.01 else { return false }
        let velocity = pullGesture.velocity(in: self)
        return velocity.y > 0 && abs(velocity.y) > abs(velocity.x) * 1.2
    }

    @objc private func pulled(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .changed:
            let down = max(0, translation.y)
            imageView.transform = CGAffineTransform(translationX: translation.x * 0.3, y: down)
            coordinator?.onPull(min(1, down / 300))
        case .ended, .cancelled:
            let velocity = gesture.velocity(in: self).y
            if gesture.state == .ended, translation.y > 120 || velocity > 900 {
                coordinator?.onDismiss()
            } else {
                UIView.animate(withDuration: 0.25) { self.imageView.transform = .identity }
                coordinator?.onPull(0)
            }
        default:
            break
        }
    }
}
