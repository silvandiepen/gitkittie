import Foundation
import MailStore

/// The cleanup dashboard in words (GKM-021). Plain, and never claims a suggestion is safe.
enum CleanupText {
    static func protection(_ reason: CleanupProtection) -> String {
        switch reason {
        case .flagged: "Flagged"
        case .inSpace: "In a space"
        case .uncertain: "Not sure what it is"
        case .quarantined: "In Quarantine"
        case .important: "A conversation or important mail"
        case .transaction: "A receipt, order, invoice or booking"
        case .recent: "Recent conversation"
        case .repliedByYou: "You replied"
        }
    }

    static func skip(_ skip: CleanupSkip) -> String {
        switch skip {
        case .notInInbox: "Not in the inbox"
        case .alreadyInTarget: "Already there"
        case .onlyOnThisMac: "Only on this Mac"
        case .severalFolders: "In several folders"
        case .onlyInAllMail: "Only in All Mail"
        }
    }

    static func messages(_ count: Int) -> String { count == 1 ? "1 message" : "\(count.formatted()) messages" }

    /// "Archive 23 messages" for the preview's heading and the confirmation's button.
    static func verb(_ operation: CleanupOperation, count: Int) -> String {
        switch operation {
        case .archive: "Archive \(messages(count))"
        case .trash: "Move \(messages(count)) to Trash"
        case .move(let folder): "Move \(messages(count)) to “\(folder)”"
        }
    }

    /// What happens at the provider, for the confirmation.
    static func consequence(_ operation: CleanupOperation) -> String {
        switch operation {
        case .archive(let target, _):
            "They move from your inbox to “\(target)” at your mail provider. Edit ▸ Undo puts all of them back."
        case .trash(let target, _):
            "They move to “\(target)” at your mail provider, which may empty it after a while. Until then, Edit ▸ Undo puts all of them back. Nothing is deleted permanently."
        case .move(let folder):
            "They move to “\(folder)” at your mail provider. Edit ▸ Undo puts all of them back."
        }
    }

    /// "Archived 23 messages."
    static func done(_ title: String, count: Int) -> String {
        "\(title.replacingOccurrences(of: "Clean Up: ", with: "")): \(messages(count))."
    }

    static func stats(_ group: CleanupGroup) -> String {
        var parts = [messages(group.count)]
        if group.count > 0 { parts.append("\(Int((group.readShare * 100).rounded()))% read") }
        if let last = group.lastSeen { parts.append("last \(last.formatted(date: .abbreviated, time: .omitted))") }
        if group.bytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: group.bytes, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }
}
