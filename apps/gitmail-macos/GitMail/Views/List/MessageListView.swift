import AppKit
import MailClassifier
import MailCore
import MailStore
import SwiftUI

/// The conversations of the selected view, newest activity first; while searching, the
/// matching messages. Arrow keys move the selection; the selected row is a tinted fill.
struct MessageListView: View {
    @Environment(AppModel.self) private var model
    @Environment(MailWindowRequests.self) private var requests
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var browser: MailBrowser { model.browser }

    private var searchText: Binding<String> {
        Binding(get: { browser.searchText }, set: { browser.typeSearch($0) })
    }

    var body: some View {
        @Bindable var senders = model.senders
        VStack(spacing: 0) {
            if requests.showsFilters || !browser.filters.isEmpty {
                SearchFilterBar()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
        .navigationTitle(title)
        .navigationSubtitle(browser.filters.sender.map { "From \(SenderText.name($0))" } ?? "")
        .searchable(text: searchText, placement: .toolbar, prompt: "Search mail")
        // Edit ▸ Find ▸ Search Mail (⌥⌘F).
        .searchFocused($searchFocused)
        .onChange(of: requests.searchRequests) { searchFocused = true }
        .toolbar { MessageActionToolbar(model: model) }
        .toolbar {
            ToolbarItem {
                Button {
                    requests.showsFilters.toggle()
                } label: {
                    Label("Filters", systemImage: browser.filters.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .help("Filter by account, category, person, date, attachments, folder or unread")
                .accessibilityValue(browser.filters.isEmpty ? "" : "On")
            }
        }
        // Always Junk or Always Trash from a row's menu (GKM-072): its preview, then Apply.
        .sheet(item: $senders.pending) { _ in RulePreviewSheet() }
        .alert("Couldn’t do that", isPresented: Binding(get: { senders.notice != nil }, set: { if !$0 { senders.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(senders.notice ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        if model.isEmpty {
            NoMailView()
        } else if browser.rows.isEmpty, !(browser.isSearching && browser.server.isShown) {
            QuietNote(browser.isSearching ? "No messages match." : browser.scope.category?.emptyNote ?? "No messages here.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(browser.rows) { row in
                            MessageRow(row: row, isSelected: browser.markedRowIDs.isEmpty ? row.id == browser.selectedRowID : browser.isMarked(row.id),
                                       showsAccount: model.accounts.count > 1,
                                       accountName: model.accounts.first { $0.id == row.latest.account }?.displayName,
                                       isPending: model.sync.replay[row.latest.account]?.status.pendingMessages.contains(row.latest.id) == true,
                                       deletedAtProvider: ProviderDeletionText.short(row.latest, account: model.account(of: row.latest)))
                                .id(row.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    listFocused = true
                                    // ⌘-click and ⇧-click mark several conversations (GKM-022).
                                    let flags = NSEvent.modifierFlags
                                    if flags.contains(.command) { browser.toggleMark(row.id); return }
                                    if flags.contains(.shift) { browser.extendMark(to: row.id); return }
                                    browser.clearMarks()
                                    Task { await browser.select(row.id) }
                                }
                                // VoiceOver: VO-Space opens it; the row menu's actions are its actions.
                                .accessibilityAction {
                                    browser.clearMarks()
                                    Task { await browser.select(row.id) }
                                }
                                .rowActions(row, model: model)
                                .draggable(SpaceLook.dragPayload(browser.threadIDs(actingOn: row.id)))
                                .contextMenu {
                                    SeeAllMailFromButton(row: row)
                                    MessageActionRowMenu(rowID: row.id)
                                    Divider()
                                    SpaceRowMenu(rowID: row.id)
                                    Divider()
                                    TaskRowMenu(row: row)
                                }
                                .onAppear {
                                    if row.id == browser.rows.last?.id { Task { await browser.loadMore() } }
                                }
                        }
                        if browser.isSearching, browser.server.isShown {
                            ServerResultsSection()
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($listFocused)
                .trashOnDelete(model)
                // ⌘A (Edit ▸ Select All) takes every row of the view, loaded or not (GKM-071).
                .onCommand(#selector(NSResponder.selectAll(_:))) { Task { await browser.selectAll() } }
                // Escape: first the selection of many, then "See All Mail from…".
                .onExitCommand {
                    if !browser.markedRowIDs.isEmpty { browser.clearMarks() }
                    else if browser.filters.sender != nil { Task { await model.leaveSenderView() } }
                }
                .onMoveCommand { direction in
                    switch direction {
                    case .down: Task { await browser.selectNext() }
                    case .up: Task { await browser.selectPrevious() }
                    default: break
                    }
                }
                .onChange(of: browser.selectedRowID) { _, id in
                    // Reduce Motion: the list jumps to the row instead of scrolling to it.
                    if let id { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
                }
            }
        }
    }

    private var title: String {
        switch model.selection {
        case .allMail: "All Mail"
        case .category(let category): category.title
        case .account: model.selectedAccount?.displayName ?? "Mail"
        case .folder(_, let name): name
        case .drafts: "Drafts"
        case .outbox: "Outbox"
        case .space(let id): model.spaces.space(id)?.name ?? "Space"
        case .attachments: "Attachments"
        case .senders: "Senders"
        case .cleanup: "Clean Up"
        }
    }
}

/// One conversation (or message): sender, subject, snippet. Unread is a dot and a heavier
/// sender; flagged is a flag; the count says how many messages the conversation has here.
private struct MessageRow: View {
    let row: ListRow
    let isSelected: Bool
    let showsAccount: Bool
    let accountName: String?
    /// A change made here has not reached the provider yet (GKM-015).
    var isPending = false
    /// "Deleted at iCloud": the provider deleted it; the copy here is kept (MAIL-075).
    var deletedAtProvider: String?

    private var summary: MessageSummary { row.latest }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(row.isUnread ? Theme.accent : .clear)
                .frame(width: 7, height: 7)
                .padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(summary.from?.displayName ?? "Unknown sender")
                        .font(.body.weight(row.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                    if row.messageCount > 1 {
                        Text("\(row.messageCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if isPending {
                        Image(systemName: "icloud.and.arrow.up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Waiting to reach the provider")
                            .accessibilityLabel("Change waiting to sync")
                    }
                    if row.isFlagged {
                        Image(systemName: "flag.fill").font(.caption).foregroundStyle(.orange)
                    }
                    if row.hasAttachments {
                        Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(MessageDate.short(summary.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(summary.subject?.isEmpty == false ? summary.subject! : "(No subject)")
                    .font(.callout.weight(row.isUnread ? .medium : .regular))
                    .lineLimit(1)
                if !summary.snippet.isEmpty {
                    Text(summary.snippet)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let deletedAtProvider {
                    Label(deletedAtProvider, systemImage: "trash.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if showsAccount, let accountName {
                    Text(accountName).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            // Selection is a tinted fill and nothing else (design-conventions, hard rule).
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Theme.accent.opacity(0.22) : .clear)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if row.isUnread { parts.append("Unread") }
        if row.isFlagged { parts.append("Flagged") }
        parts.append("From \(summary.from?.displayName ?? "unknown sender")")
        parts.append(summary.subject ?? "No subject")
        if row.messageCount > 1 { parts.append("\(row.messageCount) messages") }
        if row.hasAttachments { parts.append("Has attachments") }
        if let deletedAtProvider { parts.append(deletedAtProvider) }
        parts.append(MessageDate.short(summary.date))
        return parts.joined(separator: ", ")
    }
}

/// The first-run state: nothing stored, no account. Says what the app does with mail and where
/// it goes, and offers the one way to bring mail in that does not need an account.
private struct NoMailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.open")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("No mail yet")
                .font(.title2.weight(.semibold))
            Text("GitKittie Mail keeps every message as a file you own, in your Mail folder. Add an account, or import .eml files you already have.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            HStack(spacing: 12) {
                Button("Import Messages…") { Task { await Platform.importMessages(into: model) } }
                if let folder = model.mailFolder {
                    Button("Show Mail Folder") { Platform.reveal(folder) }
                }
            }
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
