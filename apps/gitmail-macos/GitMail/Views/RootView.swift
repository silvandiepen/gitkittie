import SwiftUI

/// Opening → the mail window, or what went wrong.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .opening:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.window)
        case .failed(let reason):
            StoreFailedView(reason: reason)
        case .ready:
            MailWindow()
        }
    }
}

/// Sidebar, message list, reader.
struct MailWindow: View {
    @Environment(AppModel.self) private var model

    /// Sidebar, middle column, detail; split out of `body` so the alerts below type-check quickly.
    private var columns: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } content: {
            ContentColumn(selection: model.selection)
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 480)
        } detail: {
            DetailColumn(showsSender: model.selection == .senders)
        }
    }

    var body: some View {
        @Bindable var model = model
        columns
        .toolbar { ComposeToolbar(model: model) }
        // Undo for actions, the Delete Permanently confirmation and action notices (GKM-015).
        .mailActionChrome(model)
        .onChange(of: model.attention.badgeCount, initial: true) { _, count in DockBadge.show(count) }
        .alert("Couldn’t do that", isPresented: Binding(
            get: { model.sending?.lastError != nil },
            set: { if !$0 { model.sending?.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.sending?.lastError ?? "")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
        .alert("Import finished", isPresented: Binding(
            get: { model.importReport != nil },
            set: { if !$0 { model.importReport = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.importReport?.summary ?? "")
        }
        .alert("Export finished", isPresented: Binding(
            get: { model.exportReport != nil },
            set: { if !$0 { model.exportReport = nil } }
        ), presenting: model.exportReport) { report in
            Button("Show in Finder") { Platform.reveal(report.folder) }
            Button("OK", role: .cancel) {}
        } message: { report in
            Text(report.summary)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.spaces.actionError != nil },
            set: { if !$0 { model.spaces.actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.spaces.actionError ?? "")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.browser.actionError != nil },
            set: { if !$0 { model.browser.actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.browser.actionError ?? "")
        }
    }
}

/// The middle column: the list for the selection, or its own view.
private struct ContentColumn: View {
    let selection: SidebarSelection

    var body: some View {
        switch selection {
        case .drafts: DraftsView()
        case .outbox: OutboxView()
        case .attachments: AttachmentLibraryView(space: nil).navigationTitle("Attachments")
        case .space(let id): SpaceView(space: id)
        case .senders: SendersListView()
        default: MessageListView()
        }
    }
}

/// The reader, or the selected sender's page in the Senders view (GKM-019).
private struct DetailColumn: View {
    let showsSender: Bool

    var body: some View {
        if showsSender { SenderDetailView() } else { ReaderView() }
    }
}

/// The store could not be opened. Says why, and offers the one thing that can help.
private struct StoreFailedView: View {
    @Environment(AppModel.self) private var model
    let reason: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Your mail couldn’t be opened")
                .font(.title2.weight(.semibold))
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 420)
            Button("Try Again") { Task { await model.open() } }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
    }
}
