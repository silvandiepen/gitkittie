import Foundation
import MailOutbox

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
