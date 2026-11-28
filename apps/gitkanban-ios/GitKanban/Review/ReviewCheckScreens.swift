import GitKanbanKit
import GitKittieKit
import SwiftUI
import UIKit

// Actions, assignment, due dates and browser checks on iPhone and iPad (ReviewSpec § 2, § 3.5,
// § 4; GITKITTIE-136). A check is a page of the request like a file: its sizes × appearance
// grid, what failed and its decision. Check opens the page full screen at the device's size
// (other sizes as a scaled preview, still answerable), with its checklist in a sheet.

// MARK: - The request's header

/// Under a request's question: who it is for, when it is due, Round 2, who you review as,
/// the read-only line on someone else's request, and what deciding it will do.
struct ReviewDetailTags: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    let showActions: () -> Void

    var body: some View {
        let forLabel = model.reviewForLabel(request)
        let lines = model.reviewActionLines(request)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let forLabel { ReviewForChip(text: forLabel, others: model.isReadOnly(request)) }
                if let due = request.dueLabel() { ReviewDueTag(label: due) }
                if request.isLaterRound { ReviewRoundTag() }
                Spacer(minLength: 0)
                Text("Reviewing as \(model.reviewingAs(request))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("reviewingAs")
            }
            if let notice = model.readOnlyNotice(request) {
                ReviewReadOnlyNotice(text: notice)
            }
            if let first = lines.first {
                Button(action: showActions) {
                    HStack(spacing: 6) {
                        Image(systemName: first.ran ? "checkmark.circle.fill" : "arrow.triangle.turn.up.right.circle")
                        Text("When decided: \(first.text)").lineLimit(1).truncationMode(.middle)
                        if lines.count > 1 { Text("+\(lines.count - 1)").monospacedDigit() }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .font(.caption)
                    .foregroundStyle(first.laneFound ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("reviewWhenDecidedButton")
            } else if !request.actionsRun.isEmpty {
                Button("Actions (\(request.actionsRun.count))", systemImage: "clock.arrow.circlepath", action: showActions)
                    .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityIdentifier("reviewWhenDecidedButton")
            }
        }
    }
}

/// "When decided" and "Actions" (with Undo while the card is untouched), in a sheet.
struct ReviewActionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ref: ReviewRef

    var body: some View {
        NavigationStack {
            ScrollView {
                if let request = model.reviewRequest(ref) {
                    ReviewActionsSection(request: request).padding()
                }
            }
            .background(Theme.window.ignoresSafeArea())
            .navigationTitle("When Decided")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.window)
    }
}

// MARK: - A check as a page of the request

/// One browser check, filling a page: the page's address, the grid, what failed, the
/// screenshots, Check, the decision and the comments.
struct CheckSlide: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    let check: ReviewCheck
    let onDecided: () -> Void
    @State private var session: ReviewCheckSession?
    /// The check open full screen (at a cell, when one was tapped).
    @State private var browsing: CheckBrowserStart?
    @State private var draft = ""
    @FocusState private var composing: Bool

    /// Open the check full screen, at a cell when one was tapped.
    private func onOpen(_ key: String?) {
        browsing = CheckBrowserStart(ref: request.ref, checkID: check.id, key: key)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.title ?? check.id).font(.headline)
                        Text(check.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if check.status == .pending {
                        Label("Waiting for you", systemImage: "circle.dashed")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .themedBar(in: Capsule())
                            .foregroundStyle(Theme.accentText)
                            .accessibilityIdentifier("checkWaiting")
                    } else {
                        Label(check.status.title, systemImage: ReviewColor.symbol(check.status))
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(ReviewColor.status(check.status), in: Capsule())
                            .foregroundStyle(.white)
                            .accessibilityIdentifier("checkStatus-\(check.status.title)")
                    }
                }
                if let revises = check.revises {
                    Label("Round 2 · redo of \(revises)", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.purple)
                }
                if check.isLocalOnly {
                    Label("Only reachable on the Mac that made it: a local address opens on that machine only.", systemImage: "network.slash")
                        .font(.callout).foregroundStyle(.orange)
                        .accessibilityIdentifier("checkLocalOnly")
                }
                if let note = check.note {
                    Text(MarkdownPage.inline(note)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                let shown = session?.check ?? check
                CheckGridView(check: shown, open: { onOpen($0) })
                let total = shown.totalProgress
                Text("Checklist \(total.answered) of \(total.total) answered")
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
                                        .frame(height: 120)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    Text(check.label(forKey: key)).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Button { onOpen(nil) } label: {
                    Label("Check", systemImage: "safari")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accentFill)
                .accessibilityIdentifier("checkOpen")

                if let session {
                    CheckDecisionButtons(session: session)
                        .onChange(of: check.status) { _, status in if status != .pending { onDecided() } }
                }
                if let by = check.decidedBy, let at = check.decidedAt {
                    Text("\(check.status.title) by \(by), \(ReviewFormat.relative(at))").font(.caption).foregroundStyle(.secondary)
                }

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Comment", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($composing)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                    Button {
                        let text = draft
                        draft = ""
                        composing = false
                        Task { await model.comment(request, check: check, text: text) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .accessibilityLabel("Send comment")
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSaving)
                }
                ForEach(Array(check.comments.enumerated()), id: \.offset) { _, comment in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(comment.by) · \(ReviewFormat.relative(comment.at))").font(.caption).foregroundStyle(.secondary)
                        Text(comment.text).font(.callout)
                    }
                }
            }
            .padding(.horizontal).padding(.vertical, 12)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("checkSlide-\(check.id)")
        .fullScreenCover(item: $browsing) { start in
            CheckBrowserView(start: start).environment(model)
        }
        .onAppear {
            if session == nil { session = ReviewCheckSession(model: model, ref: request.ref, checkID: check.id) }
        }
    }
}

// MARK: - The check, full screen

/// What opens a check full screen.
struct CheckBrowserStart: Identifiable {
    let id = UUID()
    let ref: ReviewRef
    let checkID: String
    /// The cell to start at, when one was tapped.
    let key: String?
}

/// The page full screen at the device's size, other sizes as a scaled preview; the checklist,
/// Screenshot, Next Size and the decision in a sheet over it.
struct CheckBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let start: CheckBrowserStart
    @State private var session: ReviewCheckSession?
    @State private var controller = CheckWebController()
    @State private var showsChecklist = false
    @State private var detent: PresentationDetent = .fraction(0.4)

    var body: some View {
        Group {
            if let session, let check = session.check {
                content(session, check: check)
            } else if session != nil {
                ContentUnavailableView("This check is no longer in the request", systemImage: "safari")
                    .overlay(alignment: .topLeading) { closeButton.padding() }
            } else {
                ProgressView()
            }
        }
        .background(Theme.window.ignoresSafeArea())
        .onAppear {
            guard session == nil else { return }
            let made = ReviewCheckSession(model: model, ref: start.ref, checkID: start.checkID)
            if let key = start.key { made.select(key: key) }
            session = made
            // The checklist comes up with the page, small enough to see the page above it.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                showsChecklist = true
            }
        }
        .onDisappear { Task { await session?.flush() } }
    }

    private var closeButton: some View {
        Button {
            showsChecklist = false
            dismiss()
        } label: {
            Image(systemName: "xmark").font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(Theme.card, in: Circle())
        }
        .accessibilityLabel("Close")
        .accessibilityIdentifier("checkClose")
    }

    private func content(_ session: ReviewCheckSession, check: ReviewCheck) -> some View {
        VStack(spacing: 0) {
            topBar(session, check: check)
            GeometryReader { proxy in
                let layout = CheckViewport.device(session.size, among: session.sizes, available: proxy.size)
                ZStack(alignment: .top) {
                    Color.black.opacity(0.35)
                    if let url = URL(string: check.url) {
                        CheckWebView(url: url, layout: layout, appearance: session.appearance,
                                     userAgent: CheckUserAgents.forSize(session.size), controller: controller)
                            .frame(width: layout.shown.width, height: layout.shown.height)
                            .accessibilityIdentifier("checkWebView")
                    }
                    if let error = controller.loadError {
                        ContentUnavailableView("The page did not load", systemImage: "wifi.exclamationmark", description: Text(error))
                            .background(Theme.window)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .overlay(alignment: .topLeading) { sizeBadge(layout) }
                .onAppear { session.viewport = layout.viewport }
                .onChange(of: layout) { _, new in session.viewport = new.viewport }
            }
        }
        .sheet(isPresented: $showsChecklist) {
            CheckChecklistSheet(session: session, controller: controller)
                .environment(model)
                .presentationDetents([.height(120), .fraction(0.4), .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.4)))
                .presentationBackground(Theme.window)
                .interactiveDismissDisabled()
        }
    }

    /// "This device · 440 × 812" or "Scaled preview · 1440 × 900 at 30 %".
    private func sizeBadge(_ layout: CheckViewportLayout) -> some View {
        let size = layout.viewport.replacingOccurrences(of: "x", with: " × ")
        return Text(layout.isNative ? "This device · \(size)" : layout.isScaled ? "Scaled preview · \(size) at \(layout.percent)" : size)
            .font(.caption2.weight(.semibold)).monospacedDigit()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(layout.isScaled ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Theme.card), in: Capsule())
            .foregroundStyle(layout.isScaled ? Color.white : Color.primary)
            .padding(8)
            .accessibilityIdentifier(layout.isScaled ? "checkScaledPreview" : "checkSizeBadge")
    }

    private func topBar(_ session: ReviewCheckSession, check: ReviewCheck) -> some View {
        HStack(spacing: 10) {
            closeButton
            VStack(alignment: .leading, spacing: 1) {
                Text(check.title ?? check.id).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(check.label(forKey: session.key)).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("checkCurrentSize")
            }
            Spacer(minLength: 4)
            if session.sizes.count > 1 {
                Menu {
                    Picker("Size", selection: Binding(get: { session.sizeIndex }, set: { session.sizeIndex = $0 })) {
                        ForEach(Array(session.sizes.enumerated()), id: \.offset) { index, size in
                            Text(size.viewport.map { "\(size.label) · \($0.replacingOccurrences(of: "x", with: " × "))" } ?? size.label).tag(index)
                        }
                    }
                } label: {
                    Image(systemName: "rectangle.3.group").frame(width: 36, height: 36)
                }
                .accessibilityLabel("Size")
                .accessibilityIdentifier("checkSizeMenu")
            }
            if session.appearances.count > 1 {
                Button {
                    session.appearance = session.appearance == .dark ? .light : .dark
                } label: {
                    Image(systemName: session.appearance == .dark ? "moon.fill" : "sun.max.fill").frame(width: 36, height: 36)
                }
                .accessibilityLabel(session.appearance == .dark ? "Dark, switch to light" : "Light, switch to dark")
                .accessibilityIdentifier("checkAppearance")
            }
            Menu {
                if let url = URL(string: check.url) {
                    Button("Open in Safari", systemImage: "safari") { openURL(url) }
                    Button("Copy Link", systemImage: "link") { UIPasteboard.general.url = controller.currentURL ?? url }
                }
                Button("Reload", systemImage: "arrow.clockwise") { controller.reload() }
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 36, height: 36)
            }
            .accessibilityIdentifier("checkMoreMenu")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.bar.ignoresSafeArea(edges: .top))
    }
}

/// The checklist for the size on screen, with Screenshot, Next Size and the check's decision.
struct CheckChecklistSheet: View {
    @Environment(AppModel.self) private var model
    let session: ReviewCheckSession
    let controller: CheckWebController
    @State private var shooting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.check?.label(forKey: session.key) ?? "").font(.headline)
                    Spacer()
                    Text("\(session.progress.answered) of \(session.progress.total) answered")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .accessibilityIdentifier("checkSizeProgress")
                }
                HStack(spacing: 8) {
                    Button { Task { await screenshot() } } label: { Label("Screenshot", systemImage: "camera") }
                        .buttonStyle(.bordered)
                        .disabled(shooting || session.isReadOnly)
                        .accessibilityIdentifier("checkScreenshot")
                    Spacer()
                    Button { session.previous() } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.bordered)
                        .disabled(!session.hasPrevious)
                        .accessibilityLabel("Previous size")
                    Button { session.next() } label: { Label("Next Size", systemImage: "chevron.right") }
                        .buttonStyle(.bordered)
                        .disabled(!session.hasNext)
                        .accessibilityIdentifier("checkNextSize")
                }
                if let notice = session.readOnlyNotice { ReviewReadOnlyNotice(text: notice) }
                CheckChecklistView(session: session)
                Text("Decision").font(.subheadline.weight(.semibold)).padding(.top, 4)
                CheckDecisionButtons(session: session)
                if let status = session.storedCheck?.status, status != .pending {
                    Label(status.title, systemImage: ReviewColor.symbol(status))
                        .font(.callout.weight(.semibold)).foregroundStyle(ReviewColor.status(status))
                        .accessibilityIdentifier("checkDecided-\(status.title)")
                }
                if let error = model.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            .padding()
        }
        .overlay(alignment: .bottom) { ReviewActionBannerView() }
    }

    private func screenshot() async {
        shooting = true
        defer { shooting = false }
        guard let png = await controller.screenshotPNG() else {
            model.errorMessage = "The page could not be captured."
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        await session.saveScreenshot(png)
    }
}
