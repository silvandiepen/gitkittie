import MailCore
import MailHTML
import MailReader
import MailReaderWeb
import MailStore
import QuickLook
import SwiftUI

/// One expanded message, the same safe reader as the Mac's (GKM-012): who it is really from,
/// what was blocked and why, the body (plain text natively, HTML in the locked-down web view
/// with remote content off), and its attachments, opened only when tapped.
struct MessageCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
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
                NoticeLine(systemImage: "exclamationmark.triangle", tint: .orange, text: "This message couldn’t be read: \(error)")
                    .padding(.top, 14)
            } else if let content = message.content {
                notices(content)
                body(content)
                    .padding(.top, 16)
                if !content.attachments.isEmpty {
                    AttachmentList(attachments: content.attachments) { attachment in
                        Task {
                            do { previewURL = try await browser.previewFile(for: attachment) } catch { browser.actionError = String(describing: error) }
                        }
                    }
                    .padding(.top, 20)
                }
            } else {
                ProgressView().padding(.top, 16)
            }
        }
        .padding(isOnlyMessage ? 0 : 16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isOnlyMessage ? Color.clear : Theme.panel))
        .sheet(item: $openingLink) { LinkSheet(link: $0).presentationDetents([.medium, .large]) }
        .quickLookPreview($previewURL)
        .task(id: message.content?.sender.address) { senderAllowed = await browser.senderAllowsRemoteImages(message.content?.sender.address) }
    }

    // MARK: Header

    private var header: some View {
        let sender = message.content?.sender
        let front = message.stored?.front
        return VStack(alignment: .leading, spacing: 4) {
            // At the accessibility sizes the date goes under the name (GKM-061).
            let line = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                                                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
            line {
                // The name the sender wrote, and always the address under it (ThreatModel §3).
                Text(sender?.name ?? sender?.address ?? message.summary.from?.displayName ?? "Unknown sender")
                    .font(.body.weight(.semibold))
                    .accessibilityLabel(senderLabel)
                    .accessibilityAddTraits(.isHeader)
                if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if message.summary.isFlagged {
                        Image(systemName: "flag.fill").foregroundStyle(.orange).accessibilityLabel("Flagged")
                    }
                    Text(MessageDate.short(message.summary.date))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if sender?.name != nil, let address = sender?.address {
                Text(address).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                    // Read as part of the sender line above, one element with one large target.
                    .accessibilityHidden(true)
            }
            if let front {
                if !front.to.isEmpty { Text("To \(people(front.to))").font(.subheadline).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? nil : 3) }
                if !front.cc.isEmpty { Text("Cc \(people(front.cc))").font(.subheadline).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? nil : 3) }
            }
            ForEach(sender?.warnings ?? [], id: \.self) { warning in
                NoticeLine(systemImage: "exclamationmark.shield", tint: .orange, text: warning.message)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: Notices

    @ViewBuilder private func notices(_ content: ReaderContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Deleted at the provider: the copy here is kept, and says so with when (MAIL-075).
            let account = model.account(of: message.summary)
            if let deleted = ProviderDeletionText.line(message.summary, account: account) {
                NoticeLine(systemImage: "trash.slash", tint: .secondary,
                           text: deleted + ". " + ProviderDeletionText.explanation(removesHere: account?.removesDeletedMail ?? false))
            }
            if case .html(let html) = content.body {
                remoteContentNotice(html, content: content)
                if html.trackingPixels > 0 {
                    NoticeLine(systemImage: "eye.slash", tint: .secondary,
                               text: html.trackingPixels == 1 ? "1 tracking pixel removed." : "\(html.trackingPixels) tracking pixels removed.")
                }
                if html.hasPasswordField {
                    NoticeLine(systemImage: "key", tint: .orange, text: "This message asks for a password. Never type a password into an email.")
                } else if html.hasForms {
                    NoticeLine(systemImage: "doc.text", tint: .secondary, text: "A form in this message was turned off.")
                }
            }
            if content.suspiciousLinkCount > 0 {
                NoticeLine(systemImage: "link", tint: .orange,
                           text: content.suspiciousLinkCount == 1 ? "1 link looks suspicious. Check where it goes before you open it."
                                                                  : "\(content.suspiciousLinkCount) links look suspicious. Check where they go before you open them.")
            }
            if !content.parseProblems.isEmpty {
                NoticeLine(systemImage: "wrench.adjustable", tint: .secondary, text: "This message is damaged; showing what could be read safely.")
            }
        }
        .padding(.top, 12)
    }

    @ViewBuilder private func remoteContentNotice(_ html: SanitizedHTML, content: ReaderContent) -> some View {
        if message.remoteImagesLoaded {
            VStack(alignment: .leading, spacing: 4) {
                NoticeLine(systemImage: "photo", tint: .secondary, text: "Remote images are shown.")
                if senderAllowed {
                    Button("Stop for This Sender") { Task { await browser.blockRemoteImages(for: message.id) } }
                        .font(.subheadline)
                }
            }
        } else if html.remoteImages > html.trackingPixels || html.blockedRemoteReferences > html.trackingPixels {
            VStack(alignment: .leading, spacing: 6) {
                NoticeLine(systemImage: "photo.badge.exclamationmark", tint: .secondary,
                           text: "Remote content is blocked, so the sender can’t see when you read this.")
                if html.remoteImages > html.trackingPixels {
                    HStack(spacing: 16) {
                        Button("Load Images") { Task { await browser.loadRemoteImages(for: message.id, alwaysForSender: false) } }
                        // Never offered when the sender looks spoofed: the choice is keyed by address.
                        if content.sender.warnings.isEmpty, content.sender.address != nil {
                            Button("Always for This Sender") { Task { await browser.loadRemoteImages(for: message.id, alwaysForSender: true) } }
                        }
                    }
                    .font(.subheadline)
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
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("messageBody")
                if message.showsPlainText, message.stored?.hasHTMLBody == true {
                    Button("Show Formatted Version") { Task { await browser.setShowsPlainText(false, for: message.id) } }
                        .font(.subheadline)
                }
            }
        case .html(let html):
            VStack(alignment: .leading, spacing: 10) {
                HTMLMessageView(html: html, content: content, remoteImagesLoaded: message.remoteImagesLoaded) { index in
                    openingLink = content.links.first { $0.link.index == index }
                }
                if content.plainAlternative != nil {
                    Button("Show Plain Text") { Task { await browser.setShowsPlainText(true, for: message.id) } }
                        .font(.subheadline)
                }
            }
        case .empty:
            Text("This message has no text.").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    /// The name and, always, the address: VoiceOver gets what the screen shows (ThreatModel §3).
    private var senderLabel: String {
        let sender = message.content?.sender
        let name = sender?.name ?? sender?.address ?? message.summary.from?.displayName ?? "Unknown sender"
        guard sender?.name != nil, let address = sender?.address else { return "From \(name)" }
        return "From \(name), address \(address)"
    }

    private func people(_ addresses: [MailAddress]) -> String {
        addresses.map { address in address.name.map { "\($0) <\(address.address)>" } ?? address.address }.joined(separator: ", ")
    }
}

/// Attachments with their cleaned names, type and size. Nothing is opened until one is
/// tapped; then Quick Look shows a private copy.
struct AttachmentList: View {
    let attachments: [AttachmentReference]
    let open: (AttachmentReference) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ATTACHMENTS")
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(attachments, id: \.self) { attachment in
                Button { open(attachment) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.fileName).lineLimit(typeSize.isAccessibilitySize ? 3 : 1).truncationMode(.middle)
                            Text("\(attachment.mediaType), \(MessageDate.byteCount(attachment.size))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                        }
                        Spacer()
                    }
                    .font(.subheadline)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(attachment.fileName), \(MessageDate.byteCount(attachment.size))")
                .accessibilityHint("Previews the attachment")
            }
        }
    }
}
