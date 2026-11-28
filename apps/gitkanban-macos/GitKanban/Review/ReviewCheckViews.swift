import AppKit
import GitKanbanKit
import GitKittieKit
import SwiftUI

// Browser checks on the Mac (ReviewSpec § 3.4, GITKITTIE-135): a check's row in the review
// screen, and the Check in Browser window it opens: the page at the exact viewport of a size
// (scaled down when it does not fit the screen), the checklist for that size beside it, a
// screenshot, the next size, and the check's decision.

/// Which check a Check in Browser window shows.
struct CheckWindowValue: Codable, Hashable {
    static let windowID = "check-in-browser"
    var origin: String
    var folder: String
    var check: String
    /// The cell to start at (`phone.dark`), when one was clicked.
    var key: String?

    var ref: ReviewRef { ReviewRef(origin: origin, folder: folder) }
}

/// A check in the review screen: its page, the sizes × appearance grid, what failed, the
/// screenshots, Check in Browser, the decision and the comments.
struct ReviewCheckRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let request: ReviewRequest
    let check: ReviewCheck
    /// The check was decided or commented on: "Next Waiting" goes on from here.
    var worked: () -> Void = {}
    @State private var session: ReviewCheckSession?
    @State private var draft = ""
    @State private var writing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "safari").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(check.title ?? check.id).font(.headline)
                    Text(check.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
                if check.status == .pending {
                    Label("Waiting", systemImage: "circle.dashed")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.accentFill, in: Capsule())
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("checkWaiting")
                } else {
                    Label(check.status.title, systemImage: symbol(check.status))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(color(check.status).opacity(0.15), in: Capsule())
                        .foregroundStyle(color(check.status))
                        .accessibilityIdentifier("checkStatus")
                }
            }
            if let revises = check.revises {
                Label("Round 2 · redo of \(revises)", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.purple)
            }
            if check.isLocalOnly {
                Label("A local address: it only opens on the Mac that serves it.", systemImage: "network.slash")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let note = check.note {
                Text(MarkdownPage.inline(note)).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }

            let shown = session?.check ?? check
            CheckGridView(check: shown, open: { open(at: $0) })
            let total = shown.totalProgress
            Text("Checklist \(total.answered) of \(total.total) answered · \(shown.progressLine)")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .accessibilityIdentifier("checkProgress")

            let failures = shown.failures
            if !failures.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                        Label {
                            Text("\(shown.label(forKey: failure.size)): \(failure.text)" + (failure.note.map { " — \($0)" } ?? ""))
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: failure.result == .fail ? "xmark.circle.fill" : "text.bubble.fill")
                        }
                        .font(.callout)
                        .foregroundStyle(failure.result == .fail ? Color.red : Color.teal)
                    }
                }
                .accessibilityIdentifier("checkFailures")
            }

            let shots = check.resultKeys.compactMap { key in check.results[key]?.screenshot.map { (key, $0) } }
            if !shots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shots, id: \.1) { key, file in
                            VStack(alignment: .leading, spacing: 3) {
                                ReviewImage(request: request, file: file, maxPixel: 480)
                                    .frame(height: 110)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Text(check.label(forKey: key)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button { open(at: nil) } label: { Label("Check in Browser", systemImage: "macwindow") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("checkInBrowser")
                if let url = URL(string: check.url) {
                    Button("Open in Browser", systemImage: "safari") { NSWorkspace.shared.open(url) }
                        .help("Open the page in your default browser, at whatever size its window is")
                }
                Spacer()
            }

            if let session {
                CheckDecisionButtons(session: session)
                    .simultaneousGesture(TapGesture().onEnded { worked() })
            }
            if let by = check.decidedBy, let at = check.decidedAt {
                Text("\(check.status.title) by \(by), \(ReviewFormat.relative(at))").font(.caption).foregroundStyle(.secondary)
            }
            if check.handledAt != nil {
                Label("The agent has acted on it", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(check.comments.enumerated()), id: \.offset) { _, comment in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(comment.by) · \(ReviewFormat.relative(comment.at))").font(.caption).foregroundStyle(.secondary)
                    Text(comment.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            if writing {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Comment", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(send)
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.plain).foregroundStyle(.tint)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSaving)
                        .accessibilityLabel("Send comment")
                }
            } else {
                Button("Comment…", systemImage: "text.bubble") { writing = true }
                    .buttonStyle(.link)
            }
        }
        .padding(14)
        .background(check.status == .pending ? AnyShapeStyle(Theme.card) : AnyShapeStyle(color(check.status).opacity(0.07)),
                    in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("checkRow-\(check.id)")
        .onAppear {
            if session == nil { session = ReviewCheckSession(model: model, ref: request.ref, checkID: check.id) }
        }
    }

    private func open(at key: String?) {
        worked()
        openWindow(id: CheckWindowValue.windowID, value: CheckWindowValue(origin: request.origin, folder: request.folder, check: check.id, key: key))
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        writing = false
        worked()
        Task { await model.comment(request, check: check, text: text) }
    }

    private func symbol(_ status: ReviewStatus) -> String {
        switch status {
        case .pending: return "circle.dashed"
        case .approved: return "checkmark.circle.fill"
        case .rejected: return "xmark.circle.fill"
        case .changesRequested: return "pencil.circle.fill"
        }
    }

    private func color(_ status: ReviewStatus) -> Color {
        switch status {
        case .pending: return .accentColor
        case .approved: return .green
        case .rejected: return .red
        case .changesRequested: return .orange
        }
    }
}

/// The Check in Browser window: the page at the chosen size, the checklist beside it.
struct CheckWindowView: View {
    @Environment(AppModel.self) private var model
    let value: CheckWindowValue
    @State private var session: ReviewCheckSession?
    @State private var controller = CheckWebController()
    @State private var focusedLine: String?
    @State private var shooting = false

    static let inspectorWidth: CGFloat = 360

    var body: some View {
        Group {
            if let session, let check = session.check, let request = session.request {
                content(session, check: check, request: request)
            } else if session != nil {
                ContentUnavailableView("This check is no longer in the request", systemImage: "safari")
                    .frame(width: 480, height: 320)
            } else {
                ProgressView().frame(width: 480, height: 320)
            }
        }
        .onAppear {
            guard session == nil else { return }
            let made = ReviewCheckSession(model: model, ref: value.ref, checkID: value.check)
            if let key = value.key { made.select(key: key) }
            session = made
        }
        .onDisappear { Task { await session?.flush() } }
    }

    /// The space a viewport may take: the screen, less the inspector and the window's chrome.
    static func available(screen: CGSize) -> CGSize {
        CGSize(width: max(320, screen.width - inspectorWidth - 24), height: max(320, screen.height - 110))
    }

    private func content(_ session: ReviewCheckSession, check: ReviewCheck, request: ReviewRequest) -> some View {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let layout = CheckViewport.fit(session.size, in: Self.available(screen: screen))
        let url = URL(string: check.url)
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                if let url {
                    webArea(session, url: url, layout: layout)
                } else {
                    ContentUnavailableView("“\(check.url)” is not an address", systemImage: "exclamationmark.triangle")
                        .frame(width: 480, height: 360)
                }
                statusLine(session, layout: layout)
            }
            Divider()
            inspector(session, check: check, request: request)
                .frame(width: Self.inspectorWidth)
                .frame(maxHeight: .infinity)
        }
        .navigationTitle(check.title ?? check.id)
        .navigationSubtitle(check.label(forKey: session.key))
        .toolbar { toolbar(session, check: check, url: url) }
        .background { keyboard(session) }
        .onChange(of: layout) { _, new in session.viewport = session.size.width == nil ? nil : new.viewport }
        .onAppear { session.viewport = session.size.width == nil ? nil : layout.viewport }
    }

    @ViewBuilder private func webArea(_ session: ReviewCheckSession, url: URL, layout: CheckViewportLayout) -> some View {
        if session.size.width == nil {
            // No sizes: whatever the window is. The window can be resized freely.
            GeometryReader { proxy in
                let free = CheckViewportLayout(css: proxy.size, shown: proxy.size, scale: 1, isNative: true)
                CheckWebView(url: url, layout: free, appearance: session.appearance, userAgent: CheckUserAgents.forSize(session.size),
                             controller: controller)
                    .onChange(of: proxy.size) { _, size in session.viewport = "\(Int(size.width))x\(Int(size.height))" }
                    .onAppear { session.viewport = "\(Int(proxy.size.width))x\(Int(proxy.size.height))" }
            }
            .frame(minWidth: 480, idealWidth: 1024, maxWidth: .infinity, minHeight: 360, idealHeight: 720, maxHeight: .infinity)
        } else {
            CheckWebView(url: url, layout: layout, appearance: session.appearance, userAgent: CheckUserAgents.forSize(session.size),
                         controller: controller)
                .frame(width: layout.shown.width, height: layout.shown.height)
                .overlay {
                    if let error = controller.loadError {
                        ContentUnavailableView("The page did not load", systemImage: "wifi.exclamationmark", description: Text(error))
                            .background(Theme.window)
                    }
                }
        }
    }

    private func statusLine(_ session: ReviewCheckSession, layout: CheckViewportLayout) -> some View {
        HStack(spacing: 8) {
            if session.size.width != nil {
                Text(layout.viewport.replacingOccurrences(of: "x", with: " × ")).monospacedDigit()
                if layout.isScaled {
                    Text("· shown at \(layout.percent) to fit the screen").foregroundStyle(.orange)
                        .accessibilityIdentifier("checkScaled")
                }
            } else {
                Text("The window's size")
            }
            if let look = session.appearance { Text("· \(look == .dark ? "Dark" : "Light")") }
            Spacer()
            if controller.isLoading { ProgressView().controlSize(.small) }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(width: session.size.width == nil ? nil : layout.shown.width)
        .background(Theme.bar)
    }

    private func inspector(_ session: ReviewCheckSession, check: ReviewCheck, request: ReviewRequest) -> some View {
        let progress = session.progress
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let notice = session.readOnlyNotice { ReviewReadOnlyNotice(text: notice) }
                if let note = check.note {
                    Text(MarkdownPage.inline(note)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(check.label(forKey: session.key)).font(.headline)
                    Spacer()
                    Text("\(progress.answered) of \(progress.total) answered").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .accessibilityIdentifier("checkSizeProgress")
                }
                CheckChecklistView(session: session, focusedLine: focusedLine)
                HStack(spacing: 8) {
                    Button { Task { await screenshot(session) } } label: { Label("Take Screenshot", systemImage: "camera") }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                        .disabled(shooting || session.isReadOnly || controller.webView == nil)
                        .help("Store what the page shows at this size with the check (⇧⌘S)")
                    Spacer()
                    Button { session.previous() } label: { Image(systemName: "chevron.left") }
                        .keyboardShortcut("[", modifiers: .command)
                        .disabled(!session.hasPrevious)
                        .help("Previous size (⌘[)")
                    Button { session.next() } label: { Label("Next Size", systemImage: "chevron.right") }
                        .keyboardShortcut("]", modifiers: .command)
                        .disabled(!session.hasNext)
                        .help("Next size (⌘])")
                }
                if let shot = session.screenshot {
                    ReviewImage(request: request, file: shot, maxPixel: 600)
                        .frame(maxWidth: .infinity).frame(height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Divider()
                Text("Every size").font(.subheadline.weight(.semibold))
                CheckGridView(check: check, current: session.key, open: { session.select(key: $0) })
                Divider()
                Text("Decision").font(.subheadline.weight(.semibold))
                CheckDecisionButtons(session: session, shortcuts: true)
                if check.status != .pending, let by = check.decidedBy {
                    Text("\(check.status.title) by \(by)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
        .background(Theme.panel)
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                ReviewActionBannerView()
                if let error = model.errorMessage {
                    Text(error).font(.callout).padding(10)
                        .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                        .padding(8)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        // ↑ / ↓ choose a line; P, F and N answer it.
        .onKeyPress(.upArrow) { move(session, by: -1); return .handled }
        .onKeyPress(.downArrow) { move(session, by: 1); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "pfPF")) { press in
            guard let line = focusedLine else { return .ignored }
            session.setAnswer(line, press.characters.lowercased() == "p" ? .pass : .fail, note: session.answer(line)?.note)
            return .handled
        }
    }

    private func move(_ session: ReviewCheckSession, by step: Int) {
        let lines = session.check?.checklist.map(\.id) ?? []
        guard !lines.isEmpty else { return }
        let index = focusedLine.flatMap { lines.firstIndex(of: $0) } ?? (step > 0 ? -1 : lines.count)
        focusedLine = lines[min(max(index + step, 0), lines.count - 1)]
    }

    @ToolbarContentBuilder
    private func toolbar(_ session: ReviewCheckSession, check: ReviewCheck, url: URL?) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 2) {
                Button { controller.goBack() } label: { Image(systemName: "chevron.backward") }
                    .disabled(!controller.canGoBack).help("Back")
                Button { controller.goForward() } label: { Image(systemName: "chevron.forward") }
                    .disabled(!controller.canGoForward).help("Forward")
                Button { controller.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command).help("Reload (⌘R)")
            }
        }
        ToolbarItem(placement: .principal) {
            if session.sizes.count > 1 {
                Picker("Size", selection: Binding(get: { session.sizeIndex }, set: { session.sizeIndex = $0 })) {
                    ForEach(Array(session.sizes.enumerated()), id: \.offset) { index, size in
                        Text(size.label).tag(index)
                    }
                }
                .pickerStyle(.segmented)
                .help("The size to check (⌘1 … ⌘8)")
                .accessibilityIdentifier("checkSizePicker")
            }
        }
        ToolbarItem {
            if session.appearances.count > 1 {
                Picker("Appearance", selection: Binding(get: { session.appearance ?? .light }, set: { session.appearance = $0 })) {
                    Image(systemName: "sun.max").tag(CheckAppearance.light).help("Light")
                    Image(systemName: "moon").tag(CheckAppearance.dark).help("Dark")
                }
                .pickerStyle(.segmented)
                .help("Light or dark: what the page's prefers-color-scheme sees")
                .accessibilityIdentifier("checkAppearancePicker")
            }
        }
        ToolbarItem {
            Menu {
                if let url {
                    Button("Open in Default Browser", systemImage: "safari") { NSWorkspace.shared.open(url) }
                    Button("Copy Address", systemImage: "link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString((controller.currentURL ?? url).absoluteString, forType: .string)
                    }
                }
                if let viewport = session.size.viewport {
                    Text("In another browser, size its window to \(viewport.replacingOccurrences(of: "x", with: " × "))")
                }
            } label: { Label("Open in Browser", systemImage: "safari") }
            .help("Open the page in your browser (not sized: the check is this window)")
        }
    }

    /// ⌘1 … ⌘8 choose a size. Kept out of sight: they are the keyboard's way in.
    private func keyboard(_ session: ReviewCheckSession) -> some View {
        Group {
            ForEach(Array(session.sizes.prefix(8).enumerated()), id: \.offset) { index, size in
                Button(size.label) { session.sizeIndex = index }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
    }

    private func screenshot(_ session: ReviewCheckSession) async {
        shooting = true
        defer { shooting = false }
        guard let png = await controller.screenshotPNG() else {
            model.errorMessage = "The page could not be captured."
            return
        }
        await session.saveScreenshot(png)
    }
}
