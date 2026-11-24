import Foundation
import MailCore
import MailStore

/// What the last export did, for a notice.
struct ExportReport: Equatable {
    var folder: URL
    var messages: Int
    var attachments: Int
    var failed: Int
    /// Messages whose attachments could not be downloaded first (offline): left out (GKM-036).
    var partial: Int = 0

    var summary: String {
        var text = "\(messages) \(messages == 1 ? "message" : "messages") exported as .eml with Markdown copies"
        if attachments > 0 { text += ", with \(attachments) \(attachments == 1 ? "attachment" : "attachments")" }
        text += "."
        if failed > 0 {
            text += " \(failed) \(failed == 1 ? "message was" : "messages were") left out because the original no longer matches its recorded hash."
        }
        if partial > 0 {
            text += " \(partial) \(partial == 1 ? "message was" : "messages were") left out because \(partial == 1 ? "its" : "their") attachments aren’t downloaded yet; export again when you’re online."
        }
        return text
    }
}

// Export (GKM-023): a message, a conversation, a space or an account, into a folder the person
// picks. The folder comes from an open panel, so the sandbox grants it for this session; the
// security scope is taken anyway, for a folder that came from a bookmark.
extension AppModel {
    @discardableResult
    func export(_ selection: ExportSelection, to folder: URL) async -> ExportReport? {
        guard let store = mailStore else { return nil }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        do {
            // An export holds originals only: messages with attachments still at the provider are
            // downloaded first, when they can be (GKM-036); what cannot is left out and said so.
            await completePartialMessages(try await store.partialMessages(in: selection))
            let result = try await store.export(selection, to: folder)
            let report = ExportReport(folder: result.folder, messages: result.messages, attachments: result.attachments,
                                      failed: result.failed.count, partial: result.partial.count)
            exportReport = report
            return report
        } catch {
            actionError = String(describing: error)
            return nil
        }
    }
}
