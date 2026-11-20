import Foundation
import GitKittieKit

// Following agent work: read marks on checked-off cards and which cards carry
// attachments (screenshots). See `BoardProgress` for the stages.

extension AppModel {

    /// Mark cards as read by the current reviewer (`read_at`, `read_by`). Only these two
    /// fields change; `updated_at` stays the agent's, so a later agent edit makes the card
    /// unread again.
    public func markRead(_ cards: [Card]) async {
        guard let source else { return }
        let locations = cards.compactMap { location(of: $0) }
        guard !locations.isEmpty else { return }
        let by = reviewerID
        let at = Review.timestamp(Date())
        await performWrite {
            for location in locations {
                let original = try await source.readText(location.path)
                let updated = CardText.update(original, set: ["read_at": at, "read_by": by])
                try await source.write(path: location.path, text: updated, message: "Mark \(location.path.split(separator: "/").last ?? "") read")
            }
        }
    }

    /// Mark a card unread again (clears `read_at` / `read_by`).
    public func markUnread(_ card: Card) async {
        await setCardField(card, ["read_at": nil, "read_by": nil])
    }

    /// Refresh `attachmentCardIDs` for the selected project: one listing of its
    /// `attachments/` folder, whose subfolders are card ids.
    public func loadAttachmentIndex() async {
        guard let source, let project = selectedProject else { attachmentCardIDs = []; return }
        do {
            // Most projects have no attachments folder: check before listing it.
            let top = try await source.list(project.folder)
            guard top.contains(where: { $0.kind == .directory && $0.name == "attachments" }) else {
                attachmentCardIDs = []
                return
            }
            let entries = try await source.list("\(project.folder)/attachments")
            attachmentCardIDs = Set(entries.filter { $0.kind == .directory }.map(\.name))
        } catch {
            errorMessage = "Couldn't list attachments: \(error.localizedDescription)"
        }
    }
}
