import GitKanbanKit
import GitKittieKit
import UIKit

/// Turns images, the marks made on them and the user's own pointers into a task draft.
/// Shared by the share sheet and the app's new-task sheet.
@MainActor
enum ImageTaskDrafter {
    /// Who drafts: the configured cloud provider can look at the image itself; without
    /// one, the on-device model works from the text read out of it.
    static func provider(_ app: AppModel) -> AIPontProvider? {
        app.imageAnalysisProvider ?? (OnDeviceAI.isAvailable ? .onDevice : nil)
    }

    /// The marks as a Markdown section, numbered like the boxes drawn on the image.
    static func annotationNotes(_ images: [SharedImage]) -> String {
        let annotated = images.enumerated().filter { !$0.element.annotations.isEmpty }
        guard !annotated.isEmpty else { return "" }
        var lines = ["## Annotations"]
        for (index, image) in annotated {
            if images.count > 1 { lines.append("\nScreenshot \(index + 1):") }
            for (number, annotation) in image.annotations.enumerated() {
                let comment = annotation.comment.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append("\(number + 1). \(comment.isEmpty ? "(marked, no comment)" : comment)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One line on who drafts and what they can see, or why nobody does.
    static func status(_ app: AppModel) -> String {
        if let cloud = app.imageAnalysisProvider {
            return "Drafted by \(cloud.displayName), which looks at the image itself."
        }
        if OnDeviceAI.isAvailable {
            return "Drafted on this device from your comments and the text in the image. The on-device model cannot see the picture itself; add an AI key in Tasks (account menu, AI Settings) for that."
        }
        return "Nothing is drafting: \(OnDeviceAI.unavailableReason ?? "no AI is available.") Add an AI key in Tasks (account menu, AI Settings) to have tasks written from the image."
    }

    /// A title when no model is available: the first comment on a mark.
    static func firstComment(_ images: [SharedImage]) -> String? {
        images.flatMap(\.annotations).map { $0.comment.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// Draft one task. `pointers` is text the user wrote themselves and wants followed;
    /// `confirmed` is extra context (problems they ticked). `recognizedText` caches the
    /// text read out of each image between calls. Returns `nil` when there is nothing to
    /// work from or the model gave nothing back (see `app.aiError`).
    static func draft(
        app: AppModel, images: [SharedImage], pointers: String, confirmed: String = "",
        recognizedText: inout [SharedImage.ID: String]
    ) async -> AIGeneratedTicket? {
        guard let provider = provider(app) else { return nil }
        var parts = [provider == .onDevice
            // Stated outright, or the small model fills in what the picture "shows".
            ? "Create exactly one ticket. A screenshot belongs to it, but you cannot see it: use only the comments and text below, and do not say where on the screen something is or what it looks like unless they say so."
            : "Create exactly one ticket from the attached screenshot(s)."]
        let own = pointers.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { parts.append("The user's own pointers. Follow them and keep their intent:\n\(own)") }
        if !confirmed.isEmpty { parts.append("Problems the user confirmed:\n\(confirmed)") }
        let marks = annotationNotes(images)
        if !marks.isEmpty { parts.append("Parts of the image the user marked:\n\(marks)") }
        for image in images {
            let text: String
            if let known = recognizedText[image.id] {
                text = known
            } else {
                text = await ImageTextReader.text(in: image.data)
                recognizedText[image.id] = text
            }
            if !text.isEmpty { parts.append("Text visible in the screenshot:\n\(text)") }
            // A text-only model cannot see the picture: give it at least what kind of picture it is.
            if provider == .onDevice {
                let labels = await ImageTextReader.labels(in: image.data)
                if !labels.isEmpty { parts.append("The picture appears to show: \(labels.joined(separator: ", ")).") }
            }
        }
        let attachments = provider == .onDevice ? [] : images.compactMap { $0.analysisAttachment() }
        guard parts.count > 1 || !attachments.isEmpty else { return nil }
        await app.generateTicketsFromInput(parts.joined(separator: "\n\n"), using: provider, images: attachments)
        guard var ticket = app.generatedTickets.first else { return nil }
        // The on-device model often hands a comment back as the title. A title that is
        // just what the user said is not a title: have it rewritten on its own.
        if provider == .onDevice {
            let said = images.flatMap(\.annotations).map(\.comment) + own.components(separatedBy: "\n")
            if said.contains(where: { OnDeviceAI.sameWording($0, ticket.title) }),
               let rewritten = await OnDeviceAI.title(for: ticket.title, details: ticket.description) {
                ticket.title = rewritten
            }
        }
        return ticket
    }
}
