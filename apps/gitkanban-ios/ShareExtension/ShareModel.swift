import Foundation
import GitKanbanKit
import GitKittieKit
import Observation
import UIKit

/// A board the screenshot can be filed on: one selected board inside an added repo or folder.
struct ShareDestination: Identifiable, Hashable {
    let repo: AddedRepo
    let board: SelectedBoard
    var id: String { "\(repo.id)|\(board.folder)" }
    var label: String { "\(board.name) · \(repo.displayName)" }
}

/// State of the share sheet: the shared images, where they go, and the task text.
/// Thin over `AppModel`, which does the loading and the writes.
@MainActor
@Observable
final class ShareModel {
    enum Phase: Equatable { case loading, ready, saving, done }
    /// A new task, or more material for one that already exists.
    enum Target: String, CaseIterable, Identifiable {
        case new = "New task"
        case existing = "Existing task"
        var id: String { rawValue }
    }

    let app = AppModel.shared(migratesLegacyStorage: false)
    var phase: Phase = .loading
    var images: [SharedImage] = []
    var destinations: [ShareDestination] = []
    var destinationID = ""
    var target: Target = .new
    var laneID = ""
    var existingCardID = ""
    var title = ""
    var notes = ""
    /// Suggested by the analysis, changeable. Empty means none.
    var priority = ""
    var type = ""
    /// Problems the analysis found, and the ones the user ticked to go into the task.
    var foundIssues: [String] = []
    var selectedIssues: Set<String> = []
    var includeDevice = false
    var isLoadingBoard = false
    var isAnalyzing = false
    /// What is being sent right now, and how far along it is (0…1), while saving.
    var savingStep = ""
    var savingProgress = 0.0
    var message: String?
    var appearance: UIUserInterfaceStyle = .unspecified
    var textSize: UIContentSizeCategory = .unspecified
    var analyzesAutomatically: Bool {
        didSet { defaults?.set(analyzesAutomatically, forKey: autoAnalyzeKey) }
    }

    @ObservationIgnored private let providers: [NSItemProvider]
    @ObservationIgnored private let defaults = UserDefaults(suiteName: GitKanbanSharedStorage.appGroup)
    @ObservationIgnored private let lastDestinationKey = "gitkanban.shareDestination"
    @ObservationIgnored private let autoAnalyzeKey = "gitkanban.shareAnalyzesAutomatically"
    /// Text read out of each image on-device, once.
    @ObservationIgnored private var recognizedText: [SharedImage.ID: String] = [:]
    @ObservationIgnored private var didAutoAnalyze = false
    /// The last title and notes that were written for the user rather than by them.
    @ObservationIgnored private var draftedTitle = ""
    @ObservationIgnored private var draftedNotes = ""
    @ObservationIgnored private var draftedPriority = ""
    @ObservationIgnored private var draftedType = ""
    /// The annotations the current draft was made from.
    @ObservationIgnored private var draftedAnnotations = ""

    init(providers: [NSItemProvider]) {
        self.providers = providers
        analyzesAutomatically = (defaults?.object(forKey: autoAnalyzeKey) as? Bool) ?? true
    }

    var lanes: [Lane] { app.board?.config.lanes.filter { !$0.folder.isEmpty } ?? [] }
    var priorities: [Priority] { app.board?.config.priorities ?? [] }
    var types: [String] { app.board?.config.types ?? [] }
    var destination: ShareDestination? { destinations.first { $0.id == destinationID } }
    /// Cards of the open board, for "add to an existing task".
    var cards: [Card] { app.allCards }
    var existingCard: Card? { cards.first { $0.fields.id == existingCardID } }
    var hasAnnotations: Bool { images.contains { !$0.annotations.isEmpty } }

    /// Who analyzes: the configured cloud provider can look at the image itself; without
    /// one, the on-device model works from the text read out of it.
    var analysisProvider: AIPontProvider? { ImageTaskDrafter.provider(app) }
    var analysisSendsImages: Bool { analysisProvider.map { $0 != .onDevice } ?? false }

    var canSave: Bool {
        guard phase == .ready, !isLoadingBoard, app.board != nil else { return false }
        switch target {
        case .new:
            // No title needed: one is written from the image and marks if it is empty.
            return lanes.contains { $0.id == laneID }
        case .existing:
            return existingCard != nil
        }
    }

    /// The title and notes are still what was drafted (or empty), so a new draft may replace them.
    private var textIsDrafted: Bool {
        func same(_ text: String, _ draft: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed == draft.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return same(title, draftedTitle) && same(notes, draftedNotes)
    }

    /// A title when nothing better exists: the first mark or found problem, else the date.
    private var fallbackTitle: String {
        if let first = ImageTaskDrafter.firstComment(images.taskImages) ?? foundIssues.first(where: { selectedIssues.contains($0) }) ?? foundIssues.first {
            return first
        }
        return "Screenshot \(Self.readableDate.string(from: Date()))"
    }

    /// Picking "Existing task" needs the board's cards, which were not loaded to open fast.
    func targetChanged() async {
        guard target == .existing, !app.hasTransientCards else { return }
        isLoadingBoard = true
        await app.loadTransientCards()
        isLoadingBoard = false
        if let error = app.errorMessage { message = error }
    }

    /// The markup editor closed. Redraft from the new marks, unless the user has written
    /// their own text, in which case only empty fields are filled.
    func annotationsChanged() async {
        guard annotationNotes != draftedAnnotations else { return }
        if analyzesAutomatically, analysisProvider != nil {
            await analyze(keepingTypedText: !textIsDrafted)
        } else if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title == draftedTitle {
            title = fallbackTitle
            draftedTitle = title
            draftedAnnotations = annotationNotes
        }
    }

    func load() async {
        async let restored: Void = app.restoreForSharing()
        images = await SharedImage.load(from: providers)
        await restored
        includeDevice = images.contains { DeviceDetails.isScreenshotOfThisDevice($0.pixelSize) }
        destinations = app.addedRepos.flatMap { repo in
            repo.boards.map { ShareDestination(repo: repo, board: $0) }
        }
        phase = .ready
        guard !destinations.isEmpty else { return }
        let remembered = defaults?.string(forKey: lastDestinationKey)
        let lastOpened = app.lastOpenedBoard.map { "\($0.repo.id)|\($0.folder)" }
        destinationID = [remembered, lastOpened].compactMap { $0 }
            .first { id in destinations.contains { $0.id == id } } ?? destinations[0].id
        await openDestination()
    }

    /// Load the chosen board so its lanes, cards and vocabulary are known, then analyze
    /// the images against it (once, the first time a board is open).
    func openDestination() async {
        guard let destination else { return }
        isLoadingBoard = true
        message = nil
        await app.openBoard(destination.repo, folder: destination.board.folder, transient: true)
        isLoadingBoard = false
        if let error = app.errorMessage { message = error }
        if !lanes.contains(where: { $0.id == laneID }) {
            laneID = app.quickCreateDefaultLane?.id ?? lanes.first?.id ?? ""
        }
        // Another project may not define the same priorities and types.
        if !priorities.contains(where: { $0.id == priority }) { priority = ""; draftedPriority = "" }
        if !types.contains(type) { type = ""; draftedType = "" }
        if existingCard == nil { existingCardID = "" }
        if analyzesAutomatically, !didAutoAnalyze, app.board != nil, !images.isEmpty {
            didAutoAnalyze = true
            Task { await analyze(keepingTypedText: true) }
        }
    }

    // MARK: Analysis

    var annotationNotes: String { ImageTaskDrafter.annotationNotes(images.taskImages) }

    private var issueNotes: String {
        let chosen = foundIssues.filter { selectedIssues.contains($0) }
        guard !chosen.isEmpty else { return "" }
        return (["## Problems"] + chosen.map { "- \($0)" }).joined(separator: "\n")
    }

    /// Analyze the images and draft the task. `keepingTypedText` is the automatic pass:
    /// it fills empty fields only. Without it this is "Enhance": the typed title and notes
    /// are the user's pointers, and the draft replaces them.
    func analyze(keepingTypedText: Bool) async {
        guard analysisProvider != nil, !isAnalyzing else { return }
        isAnalyzing = true
        if !keepingTypedText { message = nil }
        defer { isAnalyzing = false }

        // What the fields held when this pass started: text typed while the draft is
        // being written is the user's and must not be replaced by it.
        let titleAtStart = title, notesAtStart = notes
        // Text the user wrote is a pointer to follow; an earlier draft is not.
        let own = [(title, draftedTitle), (notes, draftedNotes)].filter { $0.0 != $0.1 }.map(\.0)
        let pointers = own.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        draftedAnnotations = annotationNotes
        var known = recognizedText
        let drafted = await ImageTaskDrafter.draft(
            app: app, images: images.taskImages, pointers: pointers, confirmed: issueNotes, recognizedText: &known)
        recognizedText = known
        guard let ticket = drafted else {
            // A draft that failed is said out loud, also on the automatic pass: otherwise
            // the task is saved bare and nothing tells why.
            if let error = app.aiError { message = "The task was not drafted: \(error)" }
            else if !keepingTypedText { message = "There is nothing to work from yet. Type a note or mark part of the image." }
            return
        }
        let titleIsEmpty = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let notesAreEmpty = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if titleIsEmpty || (!keepingTypedText && title == titleAtStart) { title = ticket.title; draftedTitle = ticket.title }
        if notesAreEmpty || (!keepingTypedText && notes == notesAtStart) { notes = ticket.description; draftedNotes = ticket.description }
        // Kind and priority are suggestions: they follow the draft until the user picks one.
        if priority == draftedPriority, let suggested = ticket.priority, priorities.contains(where: { $0.id == suggested }) {
            priority = suggested
            draftedPriority = suggested
        }
        if type == draftedType, let suggested = ticket.type, types.contains(suggested) {
            type = suggested
            draftedType = suggested
        }
        for issue in ticket.issues where !foundIssues.contains(issue) { foundIssues.append(issue) }
    }

    // MARK: Save

    /// Everything that goes into the task's description.
    private var composedBody: String {
        var sections = [notes.trimmingCharacters(in: .whitespacesAndNewlines), issueNotes, annotationNotes]
        if includeDevice { sections.append(DeviceDetails.markdown(appearance: appearance, textSize: textSize)) }
        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Write the task (or add to the chosen one), then the images, reporting each step.
    /// True when all is saved.
    func save() async -> Bool {
        guard canSave else { return false }
        phase = .saving
        message = nil
        // Add was tapped while the draft is still being written, or after new marks that
        // were not drafted from yet: finish the draft first, so the task is not saved bare.
        if target == .new, analyzesAutomatically, analysisProvider != nil {
            savingStep = "Writing the task"
            savingProgress = 0.02
            while isAnalyzing { try? await Task.sleep(for: .milliseconds(100)) }
            if textIsDrafted, !images.isEmpty, annotationNotes != draftedAnnotations || draftedTitle.isEmpty {
                await analyze(keepingTypedText: false)
            }
        }
        let steps = Double(images.count + 1)
        savingProgress = 0.05
        let stamp = TaskImage.stamp(Date())
        let cardID: String
        switch target {
        case .new:
            savingStep = "Creating the task"
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = fallbackTitle }
            guard let lane = lanes.first(where: { $0.id == laneID }),
                  let id = await app.createTask(title: title, lane: lane,
                                                priority: priority.isEmpty ? nil : priority,
                                                type: type.isEmpty ? nil : type,
                                                assignee: nil, body: composedBody) else {
                message = app.errorMessage ?? "The task could not be saved."
                phase = .ready
                return false
            }
            cardID = id
        case .existing:
            savingStep = "Updating the task"
            guard let card = existingCard else { phase = .ready; return false }
            let addition = composedBody
            let dated = addition.isEmpty ? "" : "## Added \(Self.day.string(from: Date()))\n\n\(addition)"
            guard await app.appendToCard(card, text: dated) else {
                message = app.errorMessage ?? "The task could not be updated."
                phase = .ready
                return false
            }
            cardID = card.fields.id
        }
        savingProgress = 1 / steps
        defaults?.set(destinationID, forKey: lastDestinationKey)
        var failed = 0
        for (index, image) in images.enumerated() {
            savingStep = images.count > 1 ? "Uploading image \(index + 1) of \(images.count)" : "Uploading the image"
            let file = image.attachment()
            let name = TaskImage.attachmentName(stamp: stamp, index: index, count: images.count, fileExtension: file.fileExtension)
            if await !app.attachFile(toCardID: cardID, data: file.data, filename: name) { failed += 1 }
            savingProgress = Double(index + 2) / steps
        }
        if failed > 0 {
            // The task is written; don't offer Add again and create a duplicate.
            phase = .done
            message = "The task is saved, but \(failed) of \(images.count) image(s) could not be attached: "
                + (app.errorMessage ?? "unknown error") + " Add them from the task in the app."
            return false
        }

        // Everything is saved on this device now. The sheet closes straight away and
        // `sendInBackground()` gets it out; whatever that cannot finish, the app sends.
        phase = .done
        savingProgress = 1
        return true
    }

    /// Send what was just saved, after the sheet has closed. iOS grants an extension a
    /// short while for this; anything not out by then stays in the outbox for the app.
    nonisolated func sendInBackground() {
        ProcessInfo.processInfo.performExpiringActivity(withReason: "Send the new task") { expired in
            guard !expired else { return }
            let finished = DispatchSemaphore(value: 0)
            Task { @MainActor in
                await self.app.flushOutbox()
                finished.signal()
            }
            finished.wait()
        }
    }

    private static let readableDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        return formatter
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
