import MailCompose
import MailCore
import MailOutbox
import SwiftUI

/// The drafts in the mail folder, newest first. Tap one to keep writing; swipe to delete.
struct DraftsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(MailRouter.self) private var router

    var body: some View {
        List {
            ForEach(app.sending?.drafts ?? []) { draft in
                Button { router.compose(draft.id) } label: { DraftRow(draft: draft) }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.window)
                    .swipeActions {
                        Button(role: .destructive) { Task { await app.sending?.discard(draft.id) } } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .themedList()
        .overlay { if app.sending?.drafts.isEmpty ?? true { QuietNote("No drafts.") } }
        .navigationTitle("Drafts")
        .task { await app.sending?.refreshDrafts() }
        .refreshable { await app.sending?.refreshDrafts() }
    }
}

private struct DraftRow: View {
    let draft: ComposeDraft
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // At the accessibility sizes the date goes under the recipients (GKM-061).
            let header = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                                                      : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
            header {
                Text(draft.to.isEmpty ? "No recipients" : draft.to.map { $0.name ?? $0.address }.joined(separator: ", "))
                    .font(.body.weight(.medium))
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                Text(MessageDate.short(draft.updatedAt)).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(draft.subject.isEmpty ? "(No subject)" : draft.subject).font(.subheadline).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            if !draft.body.isEmpty {
                Text(draft.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// What is waiting to be sent, and what needs a decision (GKM-014). Nothing is retried behind
/// the person's back once it may have gone out: "May have been sent" waits for a choice.
struct OutboxScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            if let sending = app.sending {
                if case .unavailable(let reason) = sending.outboxAvailability {
                    NoticeLine(systemImage: "exclamationmark.triangle", tint: .orange, text: reason)
                }
                ForEach(sending.outbox.sorted { $0.createdAt > $1.createdAt }) { entry in
                    OutboxRow(entry: entry, sending: sending)
                        .listRowBackground(Theme.window)
                }
            }
        }
        .listStyle(.plain)
        .themedList()
        .overlay { if app.sending?.outbox.isEmpty ?? true { QuietNote("Nothing waiting to be sent.") } }
        .navigationTitle("Outbox")
    }
}

private struct OutboxRow: View {
    @Environment(MailRouter.self) private var router
    @Environment(\.dynamicTypeSize) private var typeSize
    let entry: OutboxEntry
    let sending: MailSending
    @State private var confirmingSendAgain = false
    @State private var confirmingCancel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // At the accessibility sizes the state goes under the subject, and the buttons stack.
            let header = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                                                      : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
            header {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: OutboxText.symbol(entry))
                        .foregroundStyle(OutboxText.isProblem(entry) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                    Text(entry.subject.isEmpty ? "(No subject)" : entry.subject).font(.body.weight(.medium))
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                Text(OutboxText.state(entry)).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(OutboxText.recipients(entry)).font(.subheadline).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
            if let explanation = OutboxText.explanation(entry) {
                Text(explanation).font(.caption).foregroundStyle(.secondary)
            }
            let buttons = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                                                       : AnyLayout(HStackLayout(spacing: 18))
            buttons {
                if entry.canRetry { Button("Retry") { Task { await sending.retry(entry.id) } } }
                if entry.canSendAgain {
                    Button("Check Sent Again") { Task { await sending.checkAgain(entry.id) } }
                    Button("Send Again…") { confirmingSendAgain = true }
                }
                if entry.canCancel { Button("Cancel…", role: .destructive) { confirmingCancel = true } }
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("outboxRow")
        .confirmationDialog("Send it again?", isPresented: $confirmingSendAgain, titleVisibility: .visible) {
            Button("Send Again") { Task { await sending.sendAgain(entry.id) } }
        } message: {
            Text("It may already have been delivered. Mail looks in Sent once more first; if it is not there, it is sent again.")
        }
        .confirmationDialog(entry.state == .uncertain ? "Remove it from the outbox?" : "Cancel sending?",
                            isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button(entry.state == .uncertain ? "Move to Drafts" : "Cancel and Move to Drafts", role: .destructive) {
                Task { router.compose(await sending.cancel(entry.id)) }
            }
        } message: {
            Text(entry.state == .uncertain
                 ? "It may already have been delivered. Moving it to Drafts doesn’t take it back."
                 : "It goes back to Drafts, unsent.")
        }
    }
}
