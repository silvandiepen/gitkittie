import MailCore
import MailHTML
import MailReader
import MailStore
import QuickLook
import SwiftUI

/// One expanded message: who it is really from, what was blocked and why, the body (plain
/// text natively, HTML in the locked-down web view), and its attachments.
struct MessageCard: View {
    @Environment(AppModel.self) private var model
    let message: ThreadMessage
    let isOnlyMessage: Bool
    @State private var openingLink: LinkAssessment?
    @State private var previewURL: URL?
    @State private var senderAllowed = false

    private var browser: MailBrowser { model.browser }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = message.loadError {
                Notice(systemImage: "exclamationmark.triangle", tint: .orange, text: "This message couldn’t be read: \(error)")
                    .padding(.top, 14)
            } else if let content = message.content {
                notices(content)
                body(content)
                    .padding(.top, 18)
                if !content.attachments.isEmpty {
                    AttachmentList(attachments: content.attachments) { attachment in
                        Task {
                            do { previewURL = try await browser.previewFile(for: attachment) } catch { browser.actionError = String(describing: error) }
                        }
                    }
                    .padding(.top, 22)
                }
            } else {
                ProgressView().controlSize(.small).padding(.top, 18)
            }
        }
        .padding(isOnlyMessage ? 0 : 18)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isOnlyMessage ? Color.clear : Theme.panel))
        .sheet(item: $openingLink) { LinkSheet(link: $0) }
        .quickLookPreview($previewURL)
        .task(id: message.content?.sender.address) { senderAllowed = await browser.senderAllowsRemoteImages(message.content?.sender.address) }
    }

    // MARK: Header

    private var header: some View {
        let sender = message.content?.sender
        let front = message.stored?.front
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // The name the sender wrote, and always the address beside it (ThreatModel §3).
                Text(sender?.name ?? sender?.address ?? message.summary.from?.displayName ?? "Unknown sender")
                    .font(.body.weight(.semibold))
                if sender?.name != nil, let address = sender?.address {
                    Text(address).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                actions
                Text(MessageDate.long(message.summary.date))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
            if let front {
                if !front.to.isEmpty { Text("To \(people(front.to))").font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                if !front.cc.isEmpty { Text("Cc \(people(front.cc))").font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            ForEach(sender?.warnings ?? [], id: \.self) { warning in
                Notice(systemImage: "exclamationmark.shield", tint: .orange, text: warning.message)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Button {
                Task { await browser.setFlagged(!message.summary.isFlagged, for: message.id) }
            } label: {
                Image(systemName: message.summary.isFlagged ? "flag.fill" : "flag")
                    .foregroundStyle(message.summary.isFlagged ? .orange : .secondary)
            }
            .help(message.summary.isFlagged ? "Unflag" : "Flag")
            .accessibilityLabel(message.summary.isFlagged ? "Unflag" : "Flag")
            Button {
                Task { await browser.setUnread(!message.summary.isUnread, for: message.id) }
            } label: {
                Image(systemName: message.summary.isUnread ? "envelope.badge" : "envelope.open").foregroundStyle(.secondary)
            }
            .help(message.summary.isUnread ? "Mark as Read" : "Mark as Unread")
            .accessibilityLabel(message.summary.isUnread ? "Mark as Read" : "Mark as Unread")
        }
        .buttonStyle(.borderless)
    }

    // MARK: Notices

    @ViewBuilder private func notices(_ content: ReaderContent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .html(let html) = content.body {
                remoteContentNotice(html, content: content)
                if html.trackingPixels > 0 {
                    Notice(systemImage: "eye.slash", tint: .secondary,
                           text: html.trackingPixels == 1 ? "1 tracking pixel removed." : "\(html.trackingPixels) tracking pixels removed.")
                }
                if html.hasPasswordField {
                    Notice(systemImage: "key", tint: .orange, text: "This message asks for a password. Never type a password into an email.")
                } else if html.hasForms {
                    Notice(systemImage: "doc.text", tint: .secondary, text: "A form in this message was turned off.")
                }
            }
            if content.suspiciousLinkCount > 0 {
                Notice(systemImage: "link", tint: .orange,
                       text: content.suspiciousLinkCount == 1 ? "1 link looks suspicious. Check where it goes before you open it."
                                                              : "\(content.suspiciousLinkCount) links look suspicious. Check where they go before you open them.")
            }
            if !content.parseProblems.isEmpty {
                Notice(systemImage: "wrench.adjustable", tint: .secondary, text: "This message is damaged; showing what could be read safely.")
            }
        }
        .padding(.top, 12)
    }

    @ViewBuilder private func remoteContentNotice(_ html: SanitizedHTML, content: ReaderContent) -> some View {
        if message.remoteImagesLoaded {
            HStack(spacing: 10) {
                Notice(systemImage: "photo", tint: .secondary, text: "Remote images are shown.")
                if senderAllowed {
                    Button("Stop for This Sender") { Task { await browser.blockRemoteImages(for: message.id) } }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
        } else if html.remoteImages > html.trackingPixels || html.blockedRemoteReferences > html.trackingPixels {
            HStack(spacing: 10) {
                Notice(systemImage: "photo.badge.exclamationmark", tint: .secondary,
                       text: "Remote content is blocked, so the sender can’t see when you read this.")
                if html.remoteImages > html.trackingPixels {
                    Button("Load Images") { Task { await browser.loadRemoteImages(for: message.id, alwaysForSender: false) } }
                        .buttonStyle(.link)
                        .font(.callout)
                    // Never offered when the sender looks spoofed: the choice is keyed by address.
                    if content.sender.warnings.isEmpty, content.sender.address != nil {
                        Button("Always for This Sender") { Task { await browser.loadRemoteImages(for: message.id, alwaysForSender: true) } }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
            }
        }
    }

    // MARK: Body

    @ViewBuilder private func body(_ content: ReaderContent) -> some View {
        switch content.body {
        case .plain(let text):
            VStack(alignment: .leading, spacing: 10) {
                Text(text.trimmingCharacters(in: .newlines))
                    .font(.body)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if message.showsPlainText, message.stored?.hasHTMLBody == true {
                    Button("Show Formatted Version") { Task { await browser.setShowsPlainText(false, for: message.id) } }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
        case .html(let html):
            VStack(alignment: .leading, spacing: 10) {
                HTMLMessageView(html: html, content: content, remoteImagesLoaded: message.remoteImagesLoaded) { index in
                    openingLink = content.links.first { $0.link.index == index }
                }
                if content.plainAlternative != nil {
                    Button("Show Plain Text") { Task { await browser.setShowsPlainText(true, for: message.id) } }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
        case .empty:
            Text("This message has no text.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func people(_ addresses: [MailAddress]) -> String {
        addresses.map { address in address.name.map { "\($0) <\(address.address)>" } ?? address.address }.joined(separator: ", ")
    }
}

/// A one-line notice: an icon in its meaning colour and a sentence.
struct Notice: View {
    let systemImage: String
    let tint: Color
    let text: String

    var body: some View {
        Label {
            Text(text).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Attachments with their cleaned names, type and size. Nothing is opened or previewed until
/// the user clicks one; then Quick Look shows a private, quarantined copy.
struct AttachmentList: View {
    let attachments: [AttachmentReference]
    let open: (AttachmentReference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ATTACHMENTS")
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            ForEach(attachments, id: \.self) { attachment in
                Button { open(attachment) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc").foregroundStyle(.secondary)
                        Text(attachment.fileName).lineLimit(1).truncationMode(.middle)
                        Text("\(attachment.mediaType), \(MessageDate.byteCount(attachment.size))")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .font(.callout)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Preview with Quick Look")
                .accessibilityLabel("\(attachment.fileName), \(MessageDate.byteCount(attachment.size))")
                .accessibilityHint("Previews the attachment")
            }
        }
    }
}
