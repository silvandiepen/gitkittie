import MailCompose
import MailCore
import SwiftUI
import UniformTypeIdentifiers

/// New message, reply, reply all and forward (GKM-013). The draft is saved within two seconds
/// of every edit, so closing the sheet, a crash or a killed app loses at most that much; Send
/// hands it to the outbox, which never sends it twice (GKM-014).
struct ComposeScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let draftID: DraftID
    @State private var compose: ComposeModel?
    @State private var confirmingClose = false
    @State private var importing = false
    @FocusState private var focus: Focus?

    enum Focus: Hashable { case to, cc, bcc, subject, body }

    var body: some View {
        NavigationStack {
            Group {
                if let compose {
                    switch compose.phase {
                    case .loading: ProgressView()
                    case .missing: QuietNote("This draft is gone.")
                    default: form(compose)
                    }
                } else {
                    ProgressView()
                }
            }
            .background(Theme.window.ignoresSafeArea())
            .navigationTitle(compose.map { $0.subject.isEmpty ? "New Message" : $0.subject } ?? "New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .interactiveDismissDisabled(compose?.phase == .sending)
        .task {
            guard compose == nil, let sending = app.sending else { return }
            let model = ComposeModel(draftID: draftID, sending: sending)
            compose = model
            await model.load(accounts: app.accounts)
            focus = model.recipients(.to).isEmpty ? .to : .body
        }
        // Swiping the sheet away keeps the draft, as Cancel ▸ Save Draft does.
        .onDisappear { if let compose, compose.phase == .editing { Task { await compose.close() } } }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { confirmingClose = true }
                .confirmationDialog("Keep this message?", isPresented: $confirmingClose) {
                    Button("Delete Draft", role: .destructive) {
                        Task { await compose?.discard(); dismiss() }
                    }
                    Button("Save Draft") {
                        Task { await compose?.close(); dismiss() }
                    }
                }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                Task {
                    if await compose?.send() == true { dismiss() }
                }
            } label: {
                if compose?.phase == .sending { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
            }
            .disabled(compose?.phase != .editing)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("sendButton")
        }
    }

    private func form(_ compose: ComposeModel) -> some View {
        @Bindable var compose = compose
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let notice = compose.notice {
                    NoticeLine(systemImage: "exclamationmark.triangle", tint: .orange, text: notice)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
                RecipientRow(label: "To", field: .to, compose: compose, focus: $focus, focusValue: .to)
                Divider()
                if compose.showsCcAndBcc {
                    RecipientRow(label: "Cc", field: .cc, compose: compose, focus: $focus, focusValue: .cc)
                    Divider()
                    RecipientRow(label: "Bcc", field: .bcc, compose: compose, focus: $focus, focusValue: .bcc)
                    Divider()
                }
                fromRow(compose)
                Divider()
                TextField("Subject", text: $compose.subject)
                    .font(.body)
                    .focused($focus, equals: .subject)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .accessibilityIdentifier("subjectField")
                Divider()
                if !compose.draft.attachments.isEmpty {
                    attachments(compose)
                    Divider()
                }
                TextEditor(text: $compose.body)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .body)
                    .frame(minHeight: 320)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .accessibilityIdentifier("bodyField")
                saveLine(compose)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button { importing = true } label: { Image(systemName: "paperclip") }
                    .accessibilityLabel("Attach a File")
                Spacer()
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await attach(urls, to: compose) }
        }
    }

    /// The address the message goes from; tapping it also opens Cc and Bcc.
    private func fromRow(_ compose: ComposeModel) -> some View {
        HStack {
            Text("From").foregroundStyle(.secondary)
            Menu {
                ForEach(compose.identities) { identity in
                    Button(identity.address.address) { compose.selectedIdentity = identity }
                }
            } label: {
                Text(compose.selectedIdentity?.address.address ?? "Choose an account")
                    .lineLimit(1)
            }
            Spacer()
            if !compose.showsCcAndBcc {
                Button("Cc/Bcc") { compose.showsCcAndBcc = true }
                    .font(.subheadline)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func attachments(_ compose: ComposeModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(compose.draft.attachments) { attachment in
                HStack {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                    Text(attachment.filename).lineLimit(1).truncationMode(.middle)
                    Text(MessageDate.byteCount(attachment.size)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { compose.removeAttachment(attachment) } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove \(attachment.filename)")
                }
                .font(.subheadline)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func saveLine(_ compose: ComposeModel) -> some View {
        Group {
            switch compose.saveState {
            case .saved: Text("Draft saved")
            case .unsaved: Text("Saving…")
            case .failed(let reason): Text("Not saved: \(reason)").foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16).padding(.bottom, 16)
        .accessibilityIdentifier("saveState")
    }

    private func attach(_ urls: [URL], to compose: ComposeModel) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                await compose.attach(data, filename: url.lastPathComponent, mimeType: type)
            } catch {
                compose.notice = "“\(url.lastPathComponent)” couldn’t be read: \(error.localizedDescription)"
            }
        }
    }
}

/// An address field: the recipients as tokens, then what is being typed. Return, a comma or
/// leaving the field turns what was typed into recipients.
private struct RecipientRow: View {
    let label: String
    let field: ComposeModel.Field
    let compose: ComposeModel
    var focus: FocusState<ComposeScreen.Focus?>.Binding
    let focusValue: ComposeScreen.Focus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            FlowRecipients(addresses: compose.recipients(field), valid: compose.isValid) { address in
                compose.remove(address, from: field)
            } field: {
                TextField("", text: pending)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused(focus, equals: focusValue)
                    .onSubmit { compose.commitPending(field) }
                    .frame(minWidth: 120)
                    .accessibilityIdentifier("\(label.lowercased())Field")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .onChange(of: focus.wrappedValue) { old, _ in
            if old == focusValue { compose.commitPending(field) }
        }
    }

    private var pending: Binding<String> {
        Binding(get: { compose.pending[field, default: ""] }, set: { text in
            compose.pending[field] = text
            if text.hasSuffix(",") || text.hasSuffix(";") { compose.commitPending(field) }
        })
    }
}

private struct FlowRecipients<Field: View>: View {
    let addresses: [MailAddress]
    let valid: (MailAddress) -> Bool
    let remove: (MailAddress) -> Void
    @ViewBuilder let field: () -> Field

    var body: some View {
        RecipientFlow(spacing: 6) {
            ForEach(addresses, id: \.self) { address in
                Button { remove(address) } label: {
                    Text(address.name ?? address.address)
                        .font(.subheadline)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .foregroundStyle(valid(address) ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.red))
                        .background((valid(address) ? Theme.accent : .red).opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(address.address), remove")
            }
            field()
        }
    }
}

/// Wraps its children onto as many lines as they need.
private struct RecipientFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in arrange(width: bounds.width, subviews: subviews).points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x)
        }
        return (CGSize(width: width.isFinite ? width : widest, height: y + line), points)
    }
}
