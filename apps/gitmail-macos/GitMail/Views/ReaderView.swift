import MailCore
import MailStore
import SwiftUI

/// The open message as plain text. Never HTML, never a remote load: the safe reader with HTML
/// in a locked-down view is GKM-012.
struct ReaderView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let message = model.openMessage {
                ScrollView {
                    MessageBody(message: message)
                        .frame(maxWidth: 720, alignment: .leading)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 32)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if !model.messages.isEmpty {
                QuietNote("Select a message")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
    }
}

private struct MessageBody: View {
    let message: StoredMessage
    private var front: MessageFrontMatter { message.front }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(front.subject?.isEmpty == false ? front.subject! : "(No subject)")
                .font(.title.weight(.semibold))
                .tracking(-0.3)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(people(front.from))
                        .font(.body.weight(.medium))
                    Spacer(minLength: 12)
                    Text(MessageDate.long(front.sortDate))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !front.to.isEmpty { Text("To \(people(front.to))").font(.callout).foregroundStyle(.secondary) }
                if !front.cc.isEmpty { Text("Cc \(people(front.cc))").font(.callout).foregroundStyle(.secondary) }
            }
            .textSelection(.enabled)
            .padding(.top, 14)

            Group {
                if let text = message.textBody, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(text.trimmingCharacters(in: .newlines))
                        .font(.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                } else if message.hasHTMLBody {
                    Text("This message only has an HTML version, which this build doesn’t show yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("This message has no text.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 28)

            if !front.attachments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ATTACHMENTS")
                        .font(.caption.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    ForEach(front.attachments, id: \.self) { attachment in
                        Label {
                            Text(attachment.fileName) + Text("  \(MessageDate.byteCount(attachment.size))").foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "paperclip").foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                .padding(.top, 32)
            }
        }
    }

    private func people(_ addresses: [MailAddress]) -> String {
        addresses.isEmpty ? "Unknown sender" : addresses.map(\.displayName).joined(separator: ", ")
    }
}
