import MailCore
import MailStore
import SwiftUI

/// The open conversation: its messages stacked oldest to newest, the newest expanded. Older
/// messages are one line each until clicked.
struct ReaderView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let thread = model.browser.openThread {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(thread.subject?.isEmpty == false ? thread.subject! : "(No subject)")
                            .font(.title.weight(.semibold))
                            .tracking(-0.3)
                            .textSelection(.enabled)
                            .padding(.bottom, 20)
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
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(thread.id)
            } else if !model.browser.rows.isEmpty {
                QuietNote("Select a conversation")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
    }
}

/// An older message in the conversation: who, a line of it, when. Click to read it.
private struct CollapsedMessage: View {
    @Environment(AppModel.self) private var model
    let message: ThreadMessage

    var body: some View {
        Button {
            Task { await model.browser.toggleExpanded(message.id) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(message.summary.from?.displayName ?? "Unknown sender")
                    .font(.callout.weight(message.summary.isUnread ? .semibold : .medium))
                    .lineLimit(1)
                Text(message.summary.snippet)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(MessageDate.short(message.summary.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows this message")
    }
}
