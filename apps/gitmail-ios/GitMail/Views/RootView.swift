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
    /// Whether the iPad lays the mailboxes over the list (portrait) instead of beside them.
    @State private var sidebarOverlays = false
    @State private var router = MailRouter()
    @State private var undo = UndoManager()
    /// Read outside the split view: inside, its columns have their own size classes.
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // On iPad the columns widen at the accessibility sizes, where a 300 pt sidebar fits a
        // word or two per line (GKM-064). The reader keeps the rest.
        let large = typeSize.isAccessibilitySize
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $router.compactColumn) {
            MailboxesView()
                .navigationSplitViewColumnWidth(min: large ? 320 : 260, ideal: large ? 420 : 300, max: large ? 480 : 360)
        } content: {
            ContentColumn()
                // Always Junk or Always Trash from a row's menu (GKM-072), on the list it was
                // asked from: beside the split view's own sheets it kept them from opening. In
                // Settings, Blocked Senders shows its own, over that sheet.
                .sheet(item: rulePreview) { _ in RulePreviewScreen().environment(model) }
                .navigationSplitViewColumnWidth(min: 320, ideal: large ? 440 : 380, max: large ? 560 : 480)
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
            // A conversation open before the split view existed: the one the app was left on
            // (MAIL-107), or a notification's (a launch from it).
            if model.browser.openThread != nil { router.compactColumn = .detail }
        }
        .onChange(of: sizeClass, initial: true) { _, sizeClass in
            router.isCollapsed = sizeClass == .compact
        }
        // By the width alone: the keyboard shortens the view, and comparing with the height took
        // portrait for landscape whenever the keyboard was up. Too narrow for both leading columns
        // and a readable conversation (420 pt) beside them, the system lays the sidebar over the list.
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width < (large ? 420 + 440 : 300 + 380) + 420
        } action: { sidebarOverlays = $0 }
        // In portrait the system puts the sidebar away when a mailbox is chosen, but the
        // visibility stays `.all`, so the next update (a text size change, the accessibility
        // audit) laid it over the list again, where it swallowed the tap on a message (GKM-084).
        // Say what is shown instead; turned to landscape, all three columns come back.
        .onChange(of: router.mailboxChoices) {
            // (On iPhone the split view is one stack and has no sidebar to put away.)
            if !router.isCollapsed, sidebarOverlays, columns == .all { columns = .doubleColumn }
        }
        .onChange(of: sidebarOverlays) { _, overlays in
            if !overlays { columns = .all }
        }
        .onChange(of: model.browser.selectedRowID) { _, id in
            if id != nil { router.compactColumn = .detail }
        }
        // A notification was tapped (GKM-037) or a message link opened (GKM-033): its
        // conversation, even when the list doesn't show it.
        .onChange(of: model.externalOpens) {
            router.showsSettings = false
            router.compactColumn = .detail
        }
    }

    /// A sender rule change waiting for Apply, unless Settings is open (it shows its own).
    private var rulePreview: Binding<SendersModel.PendingChange?> {
        Binding(get: { router.showsSettings ? nil : model.senders.pending },
                set: { if $0 == nil { model.senders.pending = nil } })
    }

    private var currentError: String? {
        model.actionError ?? model.browser.actionError ?? model.actions.notice ?? model.spaces.actionError ?? model.senders.notice
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { currentError != nil }, set: { if !$0 { clearErrors() } })
    }

    private func clearErrors() {
        model.actionError = nil
        model.browser.actionError = nil
        model.actions.notice = nil
        model.spaces.actionError = nil
        model.senders.notice = nil
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
    /// The split view is one stack: iPhone, or iPad in a narrow window.
    var isCollapsed = false
    /// The stack is back at Mailboxes, with nothing on top of it.
    var showsMailboxesAlone: Bool { isCollapsed && compactColumn == .sidebar }
    var showsAddAccount = false
    var showsSettings = false
    /// Counts the times a mailbox is chosen in the sidebar, the same one again included.
    var mailboxChoices = 0

    func compose(_ id: DraftID?) {
        guard let id else { return }
        composing = ComposeItem(id: id)
    }
}

private struct Splash: View {
    var body: some View {
        VStack(spacing: 16) {
            // Decorative, and drawn from a text style so it grows with Dynamic Type (GKM-081):
            // Large Title at the large symbol scale is about the 44 pt it was at the default size.
            Image(systemName: "envelope")
                .font(.system(.largeTitle, weight: .ultraLight))
                .imageScale(.large)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
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
