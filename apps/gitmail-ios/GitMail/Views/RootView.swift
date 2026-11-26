import MailCompose
import MailCore
import SwiftUI

/// Mailboxes, the list and the conversation. Three columns on iPad; on iPhone the same split
/// view collapses into a stack that opens in Focused, as Mail opens in the inbox.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(MobileSession.self) private var session

    var body: some View {
        Group {
            switch model.phase {
            case .opening:
                Splash()
            case .failed(let reason):
                ContentUnavailableView("Mail can’t open", systemImage: "exclamationmark.triangle",
                                       description: Text(reason))
            case .ready:
                MailSplitView()
            }
        }
        .background(Theme.window.ignoresSafeArea())
    }
}

/// The app's navigation and the sheets every screen can open.
struct MailSplitView: View {
    @Environment(AppModel.self) private var model
    @Environment(MobileSession.self) private var session
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var router = MailRouter()
    @State private var undo = UndoManager()

    var body: some View {
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $router.compactColumn) {
            MailboxesView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } content: {
            ContentColumn()
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 480)
        } detail: {
            DetailColumn()
        }
        .environment(router)
        .sheet(item: $router.composing) { item in
            ComposeScreen(draftID: item.id)
                .environment(model)
                .environment(router)
        }
        .sheet(isPresented: $router.showsAddAccount) {
            AddAccountScreen().environment(model)
        }
        .sheet(isPresented: $router.showsSettings) {
            SettingsScreen().environment(model).environment(session).environment(router)
        }
        .alert("Something went wrong", isPresented: errorShown) {
            Button("OK", role: .cancel) { clearErrors() }
        } message: {
            Text(currentError ?? "")
        }
        .overlay(alignment: .bottom) { UndoToast(undo: undo) }
        .onAppear {
            model.actions.undoManager = undo
            model.senders.undoManager = undo
            // Opening an empty app on the list of nothing helps no one: start where accounts are added.
            if model.accounts.isEmpty { router.compactColumn = .sidebar }
            // A notification opened before the split view existed (a launch from it).
            if model.notificationOpens > 0, model.browser.openThread != nil { router.compactColumn = .detail }
        }
        .onChange(of: model.browser.selectedRowID) { _, id in
            if id != nil { router.compactColumn = .detail }
        }
        // A notification was tapped (GKM-037): its conversation, even when the list doesn't show it.
        .onChange(of: model.notificationOpens) {
            router.showsSettings = false
            router.compactColumn = .detail
        }
    }

    private var currentError: String? {
        model.actionError ?? model.browser.actionError ?? model.actions.notice ?? model.spaces.actionError
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { currentError != nil }, set: { if !$0 { clearErrors() } })
    }

    private func clearErrors() {
        model.actionError = nil
        model.browser.actionError = nil
        model.actions.notice = nil
        model.spaces.actionError = nil
    }
}

/// What the middle column shows for the sidebar's selection.
private struct ContentColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.selection {
        case .drafts: DraftsScreen()
        case .outbox: OutboxScreen()
        default: MessageListScreen()
        }
    }
}

private struct DetailColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.browser.openThread != nil {
            ThreadScreen()
        } else {
            QuietNote(model.browser.rows.isEmpty ? "" : "Choose a conversation")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.window.ignoresSafeArea())
        }
    }
}

/// The sheets and pushes that more than one screen opens.
@MainActor
@Observable
final class MailRouter {
    struct ComposeItem: Identifiable { var id: DraftID }

    var composing: ComposeItem?
    /// The column an iPhone shows: Focused's list at launch, the conversation once one is chosen.
    var compactColumn = NavigationSplitViewColumn.content
    var showsAddAccount = false
    var showsSettings = false

    func compose(_ id: DraftID?) {
        guard let id else { return }
        composing = ComposeItem(id: id)
    }
}

private struct Splash: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(Theme.accent)
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Opening your mail")
    }
}

/// A single quiet line in the middle of an empty column.
struct QuietNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
    }
}
