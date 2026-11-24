import MailCompose
import MailCore
import SwiftUI
import UniformTypeIdentifiers

/// A compose window for one draft (GKM-013). The window is restored with its draft after a
/// relaunch; everything typed is saved within two seconds.
struct ComposeWindow: View {
    let draftID: DraftID?
    @Environment(AppModel.self) private var app
    @State private var compose: ComposeModel?

    var body: some View {
        Group {
            if let compose {
                switch compose.phase {
                case .loading:
                    ProgressView().controlSize(.small)
                case .missing:
                    ComposeGone(text: "This draft has been sent or deleted.")
                case .sent:
                    ComposeGone(text: "Sent to the outbox.")
                case .editing, .sending:
                    ComposeEditor(compose: compose)
                }
            } else if draftID == nil || app.sending == nil {
                ComposeGone(text: "Nothing to write here.")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 440, idealHeight: 620)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
        .task(id: draftID) {
            guard let draftID, let sending = app.sending, compose == nil else { return }
            let model = ComposeModel(draftID: draftID, sending: sending)
            compose = model
            await model.load(accounts: app.accounts)
        }
    }
}

private struct ComposeGone: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text(text).font(.callout).foregroundStyle(.secondary)
            Button("Close Window") { dismiss() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ComposeEditor: View {
    @Bindable var compose: ComposeModel
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var confirmingDiscard = false
    @FocusState private var bodyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 12)

            if !compose.draft.attachments.isEmpty {
                AttachmentStrip(compose: compose)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
            }

            Rectangle().fill(Theme.stroke).frame(height: 1)

            ZStack(alignment: .topLeading) {
                if compose.body.isEmpty {
                    Text("Write in Markdown…")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $compose.body)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .focused($bodyFocused)
                    .accessibilityLabel("Message")
            }
            .padding(.horizontal, 23)
            .padding(.vertical, 16)

            footer
        }
        .navigationTitle(compose.subject.isEmpty ? "New Message" : compose.subject)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { importing = true } label: { Label("Attach", systemImage: "paperclip") }
                    .help("Attach files")
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button(role: .destructive) { confirmingDiscard = true } label: { Label("Discard", systemImage: "trash") }
                    .help("Delete this draft")
                Button {
                    Task { if await compose.send() { dismiss() } }
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .help("Send (⇧⌘D)")
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(compose.phase == .sending)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await attach(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            Task { await attach(files) }
            return !files.isEmpty
        }
        .confirmationDialog("Delete this draft?", isPresented: $confirmingDiscard) {
            Button("Delete Draft", role: .destructive) {
                Task { await compose.discard(); dismiss() }
            }
        } message: {
            Text("The draft and its attachments are removed from your mail folder.")
        }
        .onDisappear { Task { await compose.close() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HeaderRow(label: "From") {
                if compose.identities.isEmpty {
                    Text("Add an account to send from")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("From", selection: $compose.selectedIdentity) {
                        ForEach(compose.identities) { identity in
                            Text(identity.address.name.map { "\($0) <\(identity.address.address)>" } ?? identity.address.address)
                                .tag(Optional(identity))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            HeaderRow(label: "To") {
                HStack(alignment: .firstTextBaseline) {
                    RecipientField(compose: compose, field: .to)
                    if !compose.showsCcAndBcc {
                        Button("Cc/Bcc") { compose.showsCcAndBcc = true }
                            .buttonStyle(.borderless)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if compose.showsCcAndBcc {
                HeaderRow(label: "Cc") { RecipientField(compose: compose, field: .cc) }
                HeaderRow(label: "Bcc") { RecipientField(compose: compose, field: .bcc) }
            }
            TextField("Subject", text: $compose.subject)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .padding(.top, 8)
                .onSubmit { bodyFocused = true }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let notice = compose.notice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                Button("OK") { compose.notice = nil }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
            Spacer()
            Text(saveText)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
    }

    private var saveText: String {
        switch compose.saveState {
        case .saved: compose.draft.revision > 0 ? "Saved in Drafts" : ""
        case .unsaved: "Saving…"
        case .failed(let why): "Not saved: \(why)"
        }
    }

    private func attach(_ urls: [URL]) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                await compose.attach(data, filename: url.lastPathComponent, mimeType: type)
            } catch {
                compose.notice = "“\(url.lastPathComponent)” couldn’t be read."
            }
        }
    }
}

/// A label column and a field, as in Mail and Tasks' card editor.
private struct HeaderRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AttachmentStrip: View {
    let compose: ComposeModel

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(compose.draft.attachments) { attachment in
                HStack(spacing: 6) {
                    Image(systemName: "doc").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(attachment.filename).lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                        .foregroundStyle(.tertiary)
                    Button { compose.removeAttachment(attachment) } label: {
                        Image(systemName: "xmark").font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(attachment.filename)")
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.card, in: Capsule())
            }
        }
    }
}
