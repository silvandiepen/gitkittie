import Foundation
import GitKittieKit

/// Turns images, the marks made on them and the user's own pointers into a task draft.
/// Shared by the iPhone's share sheet and new-task sheet and the Mac's new-task sheet.
@MainActor
public enum ImageTaskDrafter {
    /// Who drafts: the configured cloud provider can look at the image itself; without
    /// one, the on-device model works from the text read out of it.
    public static func provider(_ app: AppModel) -> AIPontProvider? {
        app.imageAnalysisProvider ?? (OnDeviceAI.isAvailable ? .onDevice : nil)
    }

    /// The marks as a Markdown section, numbered like the boxes drawn on the image.
    public static func annotationNotes(_ images: [TaskImage]) -> String {
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

    /// A title when no model is available: the first comment on a mark.
    public static func firstComment(_ images: [TaskImage]) -> String? {
        images.flatMap(\.annotations).map { $0.comment.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// Draft one task. `pointers` is text the user wrote themselves and wants followed;
    /// `confirmed` is extra context (problems they ticked). `recognizedText` caches the
    /// text read out of each image between calls. Returns `nil` when there is nothing to
    /// work from or the model gave nothing back (see `app.aiError`).
    public static func draft(
        app: AppModel, images: [TaskImage], pointers: String, confirmed: String = "",
        recognizedText: inout [TaskImage.ID: String]
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

/// What came of making a task from images.
public struct ImageTaskResult: Equatable, Sendable {
    /// The new card's id.
    public let cardID: String
    /// The attachment file names that were written, in the order of the images.
    public let attached: [String]
    /// How many images could not be attached (see `errorMessage`).
    public let failed: Int
}

extension AppModel {
    /// The lane images dropped on the open board go to: the lane they were let go over,
    /// or — dropped anywhere else — the lane a new task starts in (the first lane that is
    /// neither the backlog nor finished: To do).
    public func laneForDroppedImages(onLaneID laneID: String?) -> Lane? {
        guard let columns = board?.columns else { return nil }
        if let laneID, let lane = columns.first(where: { $0.lane.id == laneID && !$0.lane.folder.isEmpty })?.lane {
            return lane
        }
        return Self.newTaskLane(in: columns.filter { !$0.lane.folder.isEmpty })
    }

    /// Images were dropped on the open board: start a new task with them in the lane they
    /// were dropped on (or To do), for the new-task sheet to mark up, draft and create.
    /// False, with `errorMessage` set, when none of what was dropped is an image.
    @discardableResult
    public func startTask(fromImages images: [TaskImage], onLaneID laneID: String?) -> Bool {
        guard !images.isEmpty else {
            errorMessage = "Only images make a task when they are dropped on the board."
            return false
        }
        guard let lane = laneForDroppedImages(onLaneID: laneID) else { return false }
        errorMessage = nil
        newTaskImages = images
        newTaskLane = lane
        return true
    }

    /// The images the new-task sheet starts with, handed over once.
    public func takeNewTaskImages() -> [TaskImage] {
        defer { newTaskImages = [] }
        return newTaskImages
    }

    /// A title for a task made from images when none was typed or drafted: the first
    /// comment on a mark, else "Screenshot" and when.
    public nonisolated static func imageTaskTitle(_ images: [TaskImage], at date: Date = Date()) -> String {
        let comment = images.flatMap(\.annotations).map { $0.comment.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return comment ?? "Screenshot \(readableDate.string(from: date))"
    }

    private nonisolated static let readableDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        return formatter
    }()

    /// Create a task in `lane` from images: the card first, with the marks listed under
    /// its notes, then each image in the card's attachments folder
    /// (`<project>/attachments/<card id>/screenshot-<stamp>.png`), the same files the
    /// iPhone's share sheet writes. An empty title becomes `imageTaskTitle`.
    /// `nil` when the card could not be written (see `errorMessage`).
    @discardableResult
    public func createTask(
        fromImages images: [TaskImage], title: String, lane: Lane,
        priority: String? = nil, type: String? = nil, assignee: String? = nil,
        epic: String? = nil, product: String? = nil, notes: String = "", at date: Date = Date()
    ) async -> ImageTaskResult? {
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = [notes.trimmingCharacters(in: .whitespacesAndNewlines), ImageTaskDrafter.annotationNotes(images)]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard let id = await createTask(
            title: typed.isEmpty ? Self.imageTaskTitle(images, at: date) : typed, lane: lane,
            priority: priority, type: type, assignee: assignee, epic: epic, product: product, body: body
        ) else { return nil }
        let stamp = TaskImage.stamp(date)
        var attached: [String] = []
        var failed = 0
        for (index, image) in images.enumerated() {
            let file = image.attachment()
            let name = TaskImage.attachmentName(stamp: stamp, index: index, count: images.count, fileExtension: file.fileExtension)
            if await attachFile(toCardID: id, data: file.data, filename: name) { attached.append(name) } else { failed += 1 }
        }
        if !attached.isEmpty { await loadAttachmentIndex() }
        return ImageTaskResult(cardID: id, attached: attached, failed: failed)
    }
}
