import MailClassifier
import MailCore
import MailStore
import SwiftUI

/// The open conversation: its messages oldest to newest, the newest expanded; older ones are
/// one line each until tapped. Archive, Trash, Flag and Reply sit in the bottom bar.
struct ThreadScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(MailRouter.self) private var router

    var body: some View {
        Group {
            if let thread = model.browser.openThread {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(thread.subject?.isEmpty == false ? thread.subject! : "(No subject)")
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)
                            .padding(.bottom, 18)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("threadSubject")
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(thread.messages) { message in
                                if message.isExpanded {
                                    MessageCard(message: message, isOnlyMessage: thread.messages.count == 1)
                                } else {
                                    CollapsedMessage(message: message)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(thread.id)
                .toolbar { toolbar(thread) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    @ToolbarContentBuilder private func toolbar(_ thread: OpenThread) -> some ToolbarContent {
        let focused = model.browser.selectedMessage
        ToolbarItemGroup(placement: .bottomBar) {
            if model.actions.isTrash(model.browser.scope) {
                Button { Task { await model.actions.requestDeletion(threads: [thread.id], in: model.browser.scope) } } label: {
                    Image(systemName: "trash.slash")
                }
                .accessibilityLabel("Delete Permanently")
            } else {
                Button { perform(.archive, thread) } label: { Image(systemName: "archivebox") }
                    .accessibilityLabel("Archive")
                    .accessibilityIdentifier("archiveButton")
                Spacer()
                Button { perform(.moveToTrash, thread) } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Move to Trash")
            }
            Spacer()
            if let focused {
                Button {
                    Task { await model.browser.setFlagged(!focused.isFlagged, for: focused.id) }
                } label: {
                    Image(systemName: focused.isFlagged ? "flag.fill" : "flag")
                }
                .accessibilityLabel(focused.isFlagged ? "Unflag" : "Flag")
                Spacer()
            }
            Menu {
                Button("Reply", systemImage: "arrowshape.turn.up.left") { answer(.reply) }
                Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { answer(.replyAll) }
                Button("Forward", systemImage: "arrowshape.turn.up.right") { answer(.forward) }
            } label: {
                Image(systemName: "arrowshape.turn.up.left")
            } primaryAction: {
                answer(.reply)
            }
            .disabled(!model.canAnswer)
            .accessibilityLabel("Reply")
            .accessibilityIdentifier("replyButton")
            Spacer()
            Button { Task { router.compose(await model.composeNew()) } } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel("New Message")
        }
        if let message = model.openMessage {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(focused?.isUnread == true ? "Mark as Read" : "Mark as Unread",
                           systemImage: focused?.isUnread == true ? "envelope.open" : "envelope.badge") {
                        if let focused { Task { await model.browser.setUnread(!focused.isUnread, for: focused.id) } }
                    }
                    Menu("Move to View") {
                        ForEach(MailPurpose.correctable, id: \.self) { purpose in
                            Button(purpose.destinationTitle) { Task { await model.move(message.front.id, to: purpose) } }
                        }
                    }
                    TaskMenuItems(messageID: message.front.id)
                    Button("Report Phishing", systemImage: "exclamationmark.shield", role: .destructive) {
                        Task { await model.markPhishing(message.front.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
    }

    private func perform(_ action: MessageAction, _ thread: OpenThread) {
        Task { await model.actions.perform(action, threads: [thread.id], in: model.browser.scope) }
    }

    private func answer(_ action: AppModel.ComposeAction) {
        Task { router.compose(await model.compose(action)) }
    }
}

/// An older message in the conversation: who, a line of it, when. Tap to read it.
private struct CollapsedMessage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let message: ThreadMessage

    var body: some View {
        Button {
            Task { await model.browser.toggleExpanded(message.id) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                // At the accessibility sizes the date goes under the sender (GKM-061).
                let header = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                                                          : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
                header {
                    Text(message.summary.from?.displayName ?? "Unknown sender")
                        .font(.subheadline.weight(message.summary.isUnread ? .semibold : .medium))
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                    Text(MessageDate.short(message.summary.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(message.summary.snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows this message")
    }
}
