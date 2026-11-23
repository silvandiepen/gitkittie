import GitKanbanKit
import GitKittieKit
import SwiftUI
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
            ? "A screenshot belongs to these notes, but you cannot see it."
            : "Create exactly one ticket from the attached screenshot(s)."]
        let own = pointers.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { parts.append("The user's own pointers. Follow them and keep their intent:\n\(own)") }
        if !confirmed.isEmpty { parts.append("Problems the user confirmed:\n\(confirmed)") }
        let marks = annotationNotes(images)
        if !marks.isEmpty {
            // The small model takes a Markdown heading for the subject of the ticket.
            parts.append(provider == .onDevice
                ? "Notes the person wrote on the screenshot, each pointing at something in it:\n" + marks.replacingOccurrences(of: "## Annotations\n", with: "")
                : "Parts of the image the user marked:\n\(marks)")
        }
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
        await app.generateTicketsFromInput(parts.joined(separator: "\n\n"), using: provider, images: attachments, single: true)
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

/// Said at the top of a form when no model can write the task: otherwise the title is
/// silently the first comment and nothing tells why.
struct NoDraftingNotice: View {
    let app: AppModel

    var body: some View {
        if ImageTaskDrafter.provider(app) == nil {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The task will not be written for you").font(.subheadline.weight(.semibold))
                        Text(OnDeviceAI.unavailableReason ?? "No AI is available.")
                        Text("Check Settings → Apple Intelligence & Siri, or add an AI key in Tasks (account menu → AI Settings). Until then the title is your first comment and the description is what you type.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .accessibilityIdentifier("noDraftingNotice")
            }
        }
    }
}
