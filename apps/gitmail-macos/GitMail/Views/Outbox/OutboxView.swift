import MailCompose
import MailOutbox
import SwiftUI

/// What is waiting to be sent, and what needs a decision (GKM-014). Nothing here is retried
/// behind the person's back when it might already have been delivered.
struct OutboxView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if let sending = app.sending {
                OutboxList(sending: sending)
            } else {
                QuietNote("The outbox opens with your mail.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
        .navigationTitle("Outbox")
    }
}

private struct OutboxList: View {
    let sending: MailSending

    var body: some View {
        let attention = sending.needsAttention
        let waiting = sending.pending.filter { $0.state == .queued || $0.state == .sending || ($0.state == .sent && !$0.isComplete) }
        if case .unavailable(let why) = sending.outboxAvailability {
            QuietNote(why)
        } else if attention.isEmpty && waiting.isEmpty {
            QuietNote("Nothing is waiting to be sent.")
        } else {
            List {
                if !attention.isEmpty {
                    Section("Needs you") {
                        ForEach(attention) { OutboxRow(entry: $0, sending: sending) }
                    }
                }
                if !waiting.isEmpty {
                    Section("Sending") {
                        ForEach(waiting) { OutboxRow(entry: $0, sending: sending) }
                    }
                }
            }
            .themedList()
        }
    }
}

private struct OutboxRow: View {
    let entry: OutboxEntry
    let sending: MailSending
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingSendAgain = false
    @State private var confirmingCancel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.subject.isEmpty ? "(No subject)" : entry.subject)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Label(OutboxText.state(entry), systemImage: OutboxText.symbol(entry))
                    .font(.callout)
                    .foregroundStyle(OutboxText.isProblem(entry) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            Text(OutboxText.recipients(entry))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let explanation = OutboxText.explanation(entry) {
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(.vertical, 6)
        .confirmationDialog("Send this message again?", isPresented: $confirmingSendAgain) {
            Button("Send Again") { Task { await sending.sendAgain(entry.id) } }
        } message: {
            Text("GitKittie Mail couldn’t confirm whether it was sent. If it was, the recipients get it twice. It looks in Sent once more before sending.")
        }
        .confirmationDialog(entry.state == .uncertain ? "Remove it from the outbox?" : "Cancel sending?", isPresented: $confirmingCancel) {
            Button(entry.state == .uncertain ? "Move to Drafts" : "Cancel and Move to Drafts", role: .destructive) {
                Task {
                    if let draft = await sending.cancel(entry.id) { openWindow(id: ComposeScene.id, value: draft) }
                }
            }
        } message: {
            Text(entry.state == .uncertain
                 ? "It may already have been sent. It goes back to Drafts and is not sent again unless you send it."
                 : "It goes back to Drafts, attachments included.")
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 14) {
            if entry.canRetry {
                Button("Retry") { Task { await sending.retry(entry.id) } }
            }
            if entry.canSendAgain {
                Button("Check Sent Again") { Task { await sending.checkAgain(entry.id) } }
                Button("Send Again…") { confirmingSendAgain = true }
            }
            if entry.canCancel {
                Button("Cancel…") { confirmingCancel = true }
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.top, 2)
    }
}

/// Words for an outbox entry. Kept out of the views' bodies so they stay plain.
enum OutboxText {
    static func state(_ entry: OutboxEntry) -> String {
        switch entry.state {
        case .queued: entry.attempts == 0 ? "Waiting" : "Will retry"
        case .sending: "Sending…"
        case .sent: entry.isComplete ? "Sent" : "Saving to Sent…"
        case .failed: "Not sent"
        case .uncertain: "May have been sent"
        }
    }

    static func symbol(_ entry: OutboxEntry) -> String {
        switch entry.state {
        case .queued: "clock"
        case .sending: "paperplane"
        case .sent: "checkmark"
        case .failed: "exclamationmark.triangle"
        case .uncertain: "questionmark.circle"
        }
    }

    static func isProblem(_ entry: OutboxEntry) -> Bool { entry.state == .failed || entry.state == .uncertain }

    static func recipients(_ entry: OutboxEntry) -> String {
        var text = "To " + (entry.visibleRecipients.isEmpty ? "—" : entry.visibleRecipients.joined(separator: ", "))
        if !entry.bcc.isEmpty { text += " · Bcc \(entry.bcc.joined(separator: ", "))" }
        return text
    }

    static func explanation(_ entry: OutboxEntry) -> String? {
        switch entry.state {
        case .uncertain:
            return (entry.lastError.map { $0 + " " } ?? "")
                + "It won’t be sent again unless you choose to."
        case .failed, .queued:
            guard let error = entry.lastError else { return nil }
            if entry.state == .queued, let next = entry.nextAttemptAt {
                return "\(error) Trying again \(next.formatted(.relative(presentation: .named)))."
            }
            return error
        default:
            return entry.lastError
        }
    }
}
