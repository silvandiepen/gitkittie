import GitKittieKit
import GitKanbanKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A card's detail: opens in a read view with the description rendered as Markdown,
/// with an Edit button that flips to an editable form. Saving commits over the
/// provider API (git-pont) and reloads the board.
struct CardDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let card: Card

    @State private var editing = false
    @State private var confirmDelete = false
    @State private var attachments: [BoardFileEntry] = []
    @State private var showCardReviews = false
    @State private var showImporter = false
    @State private var showPhotoPicker = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var shareItem: CardShareItem?

    // Editable state.
    @State private var title = ""
    @State private var laneID = ""
    @State private var priority = ""
    @State private var type = ""
    @State private var assignee = ""
    @State private var epic = ""
    @State private var body_ = ""
    @State private var seeded = false

    private var config: EffectiveConfig? { model.board?.config }
    private var lanes: [Lane] { config?.lanes ?? [] }
    private var priorities: [Priority] { config?.priorities ?? [] }
    private var users: [User] { config?.users ?? [] }
    private var types: [String] { config?.types ?? [] }
    private var epics: [Epic] { config?.epics ?? [] }

    private var laneForStatus: Lane? { lanes.first { $0.status == card.fields.status } }
    /// The card as currently loaded (the sheet's copy goes stale after a write).
    private var current: Card {
        model.board?.columns.lazy.flatMap(\.cards).first { $0.id == card.id } ?? card
    }
    private var isCheckedOff: Bool {
        guard let lane = laneForStatus else { return false }
        return BoardProgress.stage(for: lane, in: lanes) == .checkedOff
    }

    private var navigationTitle: String {
        let title = card.fields.title.isEmpty ? card.fields.id : card.fields.title
        if title.isEmpty { return "Task" }
        return title
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .confirmationDialog("Delete this task?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { Task { await model.deleteCard(card); dismiss() } }
                }
                .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                    handleImport(result)
                }
                .photosPicker(isPresented: $showPhotoPicker, selection: $pickedPhotos, maxSelectionCount: 5, matching: .images)
                .onChange(of: pickedPhotos) { _, items in attachPhotos(items) }
                .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
                .sheet(isPresented: $showCardReviews) { NavigationStack { ReviewListView(cardID: card.fields.id) }.environment(model) }
                .task { await loadAttachments() }
        }
        .onAppear(perform: seed)
        // Opening a card is looking at it. Recorded when it closes, so the "updated"
        // mark stays visible while it is open.
        .onDisappear { model.markSeen(card) }
    }

    private func loadAttachments() async { attachments = await model.attachments(for: card) }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let name = url.lastPathComponent
        Task { if await model.attachFile(to: card, data: data, filename: name) { await loadAttachments() } }
    }

    /// Attach images picked from Photos (screenshots, mostly), keeping their format.
    private func attachPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        pickedPhotos = []
        Task {
            let stamp = Self.attachmentStamp.string(from: Date())
            for (index, item) in items.enumerated() {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "png"
                let suffix = items.count > 1 ? "-\(index + 1)" : ""
                await model.attachFile(to: card, data: data, filename: "photo-\(stamp)\(suffix).\(ext)")
            }
            await loadAttachments()
        }
    }

    private static let attachmentStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// Photos or Files — the two places a screenshot or document comes from.
    private func addAttachmentMenu<L: View>(@ViewBuilder label: () -> L) -> some View {
        Menu {
            Button { showPhotoPicker = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
            Button { showImporter = true } label: { Label("Files", systemImage: "folder") }
        } label: { label() }
    }

    private func share(_ entry: BoardFileEntry) async {
        guard let data = await model.readAttachment(path: entry.path) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(entry.name)
        guard (try? data.write(to: url)) != nil else { return }
        shareItem = CardShareItem(url: url)
    }

    @ViewBuilder private var content: some View {
        if editing {
            editForm.toolbar { editToolbar }
        } else {
            readView.toolbar { readToolbar }
        }
    }

    // MARK: Read

    private var readView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Show ID as subtitle if different from title
                if !card.fields.id.isEmpty && card.fields.id != card.fields.title {
                    Text(card.fields.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                // Metadata chips
                metadata

                if isCheckedOff { readBanner }

                // Description - strip leading title if it matches
                let body = stripLeadingTitle(card.body, title: card.fields.title)
                if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No description.")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                } else {
                    MarkdownWebView(markdown: body)
                }

                // Review requests linked to this card (`card:` in their review.md).
                let cardReviews = model.reviews(for: card)
                if !cardReviews.isEmpty {
                    Divider()
                    Button { showCardReviews = true } label: {
                        let pending = cardReviews.reduce(0) { $0 + $1.summary.pending }
                        Label(pending > 0 ? "\(pending) asset\(pending == 1 ? "" : "s") to review" : "\(cardReviews.count) review\(cardReviews.count == 1 ? "" : "s")",
                              systemImage: "checkmark.seal")
                    }
                }

                // Attachments: only show if present or expanded via add button
                if !attachments.isEmpty || showImporter {
                    Divider()
                    attachmentsSection
                } else {
                    // Compact add attachment button when no attachments
                    HStack {
                        Spacer()
                        addAttachmentMenu {
                            Label("Add Attachment", systemImage: "paperclip")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    /// Checked-off work: whether Sil has read it, and the button to say so.
    @ViewBuilder private var readBanner: some View {
        let fields = current.fields
        if BoardProgress.isUnread(fields) {
            Button { Task { await model.markRead([current]) } } label: {
                Label(fields.readAt == nil ? "Mark as Read" : "Updated since you read it. Mark as Read",
                      systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("markRead")
        } else if let readAt = fields.readAt {
            HStack {
                Label("Read \(ReviewFormat.relative(readAt))\(fields.readBy.map { " by \($0)" } ?? "")",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Spacer()
                Button("Mark Unread") { Task { await model.markUnread(current) } }
                    .font(.caption)
            }
        }
    }

    private var imageAttachments: [BoardFileEntry] { attachments.filter { AttachmentRow.isImage($0.name) } }

    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Attachments").font(.subheadline.weight(.medium))
                Spacer()
                addAttachmentMenu { Label("Add", systemImage: "paperclip").font(.caption) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            // Screenshots and other images, large enough to judge the work.
            ForEach(imageAttachments, id: \.path) { entry in
                AttachmentImage(entry: entry)
                    .contextMenu {
                        Button("Share", systemImage: "square.and.arrow.up") { Task { await share(entry) } }
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            Task { await model.deleteAttachment(path: entry.path); await loadAttachments() }
                        }
                    }
            }
            ForEach(attachments.filter { !AttachmentRow.isImage($0.name) }, id: \.path) { entry in
                AttachmentRow(entry: entry)
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await share(entry) } }
                    .contextMenu {
                        Button("Share", systemImage: "square.and.arrow.up") { Task { await share(entry) } }
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            Task { await model.deleteAttachment(path: entry.path); await loadAttachments() }
                        }
                    }
            }
        }
    }

    @ViewBuilder private var metadata: some View {
        let cfg = config ?? EffectiveConfig()
        HStack(spacing: 6) {
            if let lane = laneForStatus {
                chip(lane.name, color: laneColor(lane, cfg))
            }
            if let p = card.fields.priority, let color = PriorityPalette.color(p, priorities) {
                chip(p, color: color)
            }
            if let t = card.fields.type { chip(t, color: .secondary) }
            if let e = card.fields.epic {
                chip(epics.first { $0.id == e }?.name ?? e, color: .purple)
            }
            if let a = card.fields.assignee {
                Label("@\(a)", systemImage: "person.crop.circle").labelStyle(.titleOnly)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    @ToolbarContentBuilder private var readToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    // MARK: Edit

    private var editForm: some View {
        Form {
            Section("Task") { TextField("Title", text: $title) }
            Section {
                Picker("Lane", selection: $laneID) {
                    ForEach(lanes) { Text($0.name).tag($0.id) }
                }
                if !priorities.isEmpty {
                    Picker("Priority", selection: $priority) {
                        Text("None").tag("")
                        ForEach(priorities, id: \.id) { Text($0.name ?? $0.id).tag($0.id) }
                    }
                }
                if types.isEmpty {
                    TextField("Type", text: $type)
                } else {
                    Picker("Type", selection: $type) {
                        Text("None").tag("")
                        ForEach(types, id: \.self) { Text($0).tag($0) }
                    }
                }
                if users.isEmpty {
                    TextField("Assignee", text: $assignee)
                } else {
                    Picker("Assignee", selection: $assignee) {
                        Text("Unassigned").tag("")
                        ForEach(users, id: \.id) { Text($0.name ?? $0.id).tag($0.id) }
                    }
                }
                if !epics.isEmpty {
                    Picker("Epic", selection: $epic) {
                        Text("None").tag("")
                        ForEach(epics, id: \.id) { Text($0.name ?? $0.id).tag($0.id) }
                    }
                }
            }
            Section("Description") {
                TextEditor(text: $body_).frame(minHeight: 160)
                    .font(.system(.body, design: .monospaced))
            }
        }
    }

    @ToolbarContentBuilder private var editToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { seeded = false; seed(); editing = false }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
                Task {
                    await model.updateCard(card, title: title, laneID: laneID, priority: priority,
                                           type: type, assignee: assignee, epic: epic, body: body_)
                    dismiss()
                }
            }
            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func seed() {
        guard !seeded else { return }
        seeded = true
        title = card.fields.title
        laneID = laneForStatus?.id ?? lanes.first?.id ?? ""
        priority = card.fields.priority ?? ""
        type = card.fields.type ?? ""
        assignee = card.fields.assignee ?? ""
        epic = card.fields.epic ?? ""
        body_ = card.body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripLeadingTitle(_ markdown: String, title: String) -> String {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("# ") {
            let lines = trimmed.components(separatedBy: .newlines)
            if let firstLine = lines.first {
                let headingText = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if headingText.lowercased() == title.lowercased() || headingText.isEmpty {
                    return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return markdown
    }
}

/// Create a task in a lane.
struct NewTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let lane: Lane

    @State private var title = ""
    @State private var laneID = ""
    @State private var priority = ""
    @State private var type = ""
    @State private var assignee = ""
    @State private var epic = ""
    @State private var body_ = ""
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var images: [SharedImage] = []
    /// The image open in the markup editor.
    @State private var annotating: SharedImage.ID?
    @State private var isDrafting = false
    /// What was last written for the user, so a new draft may replace it but never their own text.
    @State private var draftedTitle = ""
    @State private var draftedBody = ""
    @State private var recognizedText: [SharedImage.ID: String] = [:]

    private var config: EffectiveConfig? { model.board?.config }
    private var lanes: [Lane] { config?.lanes.filter { !$0.folder.isEmpty } ?? [] }
    private var priorities: [Priority] { config?.priorities ?? [] }
    private var users: [User] { config?.users ?? [] }
    private var types: [String] { config?.types ?? [] }
    private var epics: [Epic] { config?.epics ?? [] }
    private var targetLane: Lane { lanes.first { $0.id == laneID } ?? lane }

    var body: some View {
        NavigationStack {
            Form {
                Section("New Task") {
                    TextField("Title", text: $title)
                    Picker("Lane", selection: $laneID) {
                        ForEach(lanes) { Text($0.name).tag($0.id) }
                    }
                }
                Section {
                    if !priorities.isEmpty {
                        Picker("Priority", selection: $priority) {
                            Text("None").tag("")
                            ForEach(priorities, id: \.id) { Text($0.name ?? $0.id).tag($0.id) }
                        }
                    }
                    if types.isEmpty {
                        TextField("Type", text: $type)
                    } else {
                        Picker("Type", selection: $type) {
                            Text("None").tag("")
                            ForEach(types, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    if users.isEmpty {
                        TextField("Assignee", text: $assignee)
                    } else {
                        Picker("Assignee", selection: $assignee) {
                            Text("Unassigned").tag("")
                            ForEach(users, id: \.id) { Text($0.name ?? $0.id).tag($0.id) }
                        }
                    }
                    if !epics.isEmpty {
                        Picker("Epic", selection: $epic) {
                            Text("None").tag("")
                            ForEach(epics, id: \.id) { Text($0.name ?? $0.id).tag($0.id) }
                        }
                    }
                }
                Section("Description") { TextEditor(text: $body_).frame(minHeight: 120) }
                Section {
                    if !images.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(images) { image in
                                    if let thumbnail = image.thumbnail {
                                        Button { annotating = image.id } label: {
                                            Image(uiImage: thumbnail)
                                                .resizable()
                                                .scaledToFit()
                                                .frame(height: 120)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                                .overlay(alignment: .bottomTrailing) {
                                                    Label(image.annotations.isEmpty ? "Mark up" : "\(image.annotations.count)",
                                                          systemImage: "pencil.tip.crop.circle")
                                                        .font(.caption2.weight(.semibold))
                                                        .padding(.horizontal, 6).padding(.vertical, 3)
                                                        .background(.regularMaterial, in: Capsule())
                                                        .padding(4)
                                                }
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Mark up image")
                                        .overlay(alignment: .topTrailing) {
                                            Button { images.removeAll { $0.id == image.id } } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .symbolRenderingMode(.palette)
                                                    .foregroundStyle(.white, .black.opacity(0.6))
                                                    .font(.title3)
                                            }
                                            .buttonStyle(.plain)
                                            .padding(4)
                                            .accessibilityLabel("Remove image")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    PhotosPicker(selection: $pickedPhotos, maxSelectionCount: 5, matching: .images) {
                        Label(images.isEmpty ? "Add Images" : "Add More", systemImage: "photo.on.rectangle")
                    }
                    .accessibilityIdentifier("newTaskAddImages")
                    if isDrafting {
                        HStack(spacing: 10) { ProgressView(); Text("Writing a title and description").foregroundStyle(.secondary) }
                    }
                } header: {
                    Text("Images")
                } footer: {
                    if !images.isEmpty {
                        Text("Tap an image to mark what is wrong. An empty title and description are written from the image and your marks.")
                    }
                }
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { if laneID.isEmpty { laneID = lane.id } }
            .onChange(of: pickedPhotos) { _, items in
                guard !items.isEmpty else { return }
                pickedPhotos = []
                Task {
                    for item in items {
                        guard let raw = try? await item.loadTransferable(type: Data.self) else { continue }
                        // PNG and JPEG are kept; anything else (HEIC) becomes JPEG so every client shows it.
                        let isPNG = item.supportedContentTypes.contains(.png)
                        let isJPEG = item.supportedContentTypes.contains(.jpeg)
                        guard let data = isPNG || isJPEG ? raw : UIImage(data: raw)?.jpegData(compressionQuality: 0.85) else { continue }
                        images.append(SharedImage(data: data, fileExtension: isPNG ? "png" : "jpg",
                                                  thumbnail: SharedImage.downsampled(data, maxPixel: 480)))
                    }
                    await draftFromImages()
                }
            }
            .sheet(item: annotatingBinding, onDismiss: { Task { await draftFromImages() } }) { $image in
                AnnotationEditor(image: $image)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        // Close at once: the task is saved locally and sent in the
                        // background (see the indicator in the corner).
                        let model = model, lane = targetLane, images = images
                        let marks = ImageTaskDrafter.annotationNotes(images)
                        let title = title.trimmingCharacters(in: .whitespaces).isEmpty
                            ? (ImageTaskDrafter.firstComment(images) ?? "New task") : title
                        let body = [body_.trimmingCharacters(in: .whitespacesAndNewlines), marks]
                            .filter { !$0.isEmpty }.joined(separator: "\n\n")
                        let (priority, type, assignee, epic) = (priority, type, assignee, epic)
                        dismiss()
                        Task {
                            let id = await model.createTask(
                                title: title, lane: lane,
                                priority: priority.isEmpty ? nil : priority,
                                type: type.isEmpty ? nil : type,
                                assignee: assignee.isEmpty ? nil : assignee,
                                epic: epic.isEmpty ? nil : epic,
                                body: body
                            )
                            guard let id else { return }
                            for (index, image) in images.enumerated() {
                                let file = image.attachment()
                                await model.attachFile(toCardID: id, data: file.data,
                                                       filename: "image-\(index + 1).\(file.fileExtension)")
                            }
                            if !images.isEmpty { await model.loadAttachmentIndex() }
                        }
                    }
                    // With an image a title is written if none is given.
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty && images.isEmpty)
                }
            }
        }
    }

    /// The binding to the image being marked up, for the editor sheet.
    private var annotatingBinding: Binding<Binding<SharedImage>?> {
        Binding(
            get: { $images.first { $0.wrappedValue.id == annotating } },
            set: { if $0 == nil { annotating = nil } })
    }

    /// Write the title and description from the images and marks, where the user has not
    /// written their own: a field is only filled when it is empty or still an earlier draft.
    private func draftFromImages() async {
        guard !images.isEmpty, !isDrafting else { return }
        func open(_ text: String, _ draft: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed == draft.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard open(title, draftedTitle) || open(body_, draftedBody) else { return }
        let titleAtStart = title, bodyAtStart = body_
        let own = [(title, draftedTitle), (body_, draftedBody)].filter { !open($0.0, $0.1) }.map(\.0).joined(separator: "\n")
        isDrafting = true
        var known = recognizedText
        let ticket = await ImageTaskDrafter.draft(app: model, images: images, pointers: own, recognizedText: &known)
        recognizedText = known
        isDrafting = false
        if let ticket {
            // Only where nothing was typed while the draft was being written.
            if open(title, draftedTitle), title == titleAtStart { title = ticket.title; draftedTitle = ticket.title }
            if open(body_, draftedBody), body_ == bodyAtStart { body_ = ticket.description; draftedBody = ticket.description }
            if priority.isEmpty, let suggested = ticket.priority, priorities.contains(where: { $0.id == suggested }) { priority = suggested }
            if type.isEmpty, let suggested = ticket.type, types.contains(suggested) { type = suggested }
        } else if open(title, draftedTitle), let comment = ImageTaskDrafter.firstComment(images) {
            title = comment
            draftedTitle = comment
        }
    }
}

/// AI Quick Create: type natural language, AI generates tickets.
struct QuickCreateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var showSettings = false
    @State private var selectedLaneID: String = ""

    private var lanes: [Lane] {
        model.board?.config.lanes.filter { !$0.folder.isEmpty } ?? []
    }

    private var selectedLane: Lane? {
        lanes.first { $0.id == selectedLaneID }
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            VStack(spacing: 0) {
                // Input area
                VStack(alignment: .leading, spacing: 12) {
                    Text("Describe what you need")
                        .font(.headline)
                    TextEditor(text: $input)
                        .font(.body)
                        .frame(minHeight: 100)
                        .padding(8)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    Text("AI will analyze your input and create one or more tickets with appropriate fields.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()

                Divider()

                // Results area
                if model.isGeneratingTickets {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Generating tickets…").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.aiError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        if !model.isAIConfigured {
                            Button("Configure AI") { showSettings = true }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.generatedTickets.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Enter a description and tap Generate")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        // Lane picker when tickets are generated
                        HStack {
                            Text("Create in:")
                                .font(.subheadline)
                            Picker("Lane", selection: $selectedLaneID) {
                                ForEach(lanes) { lane in
                                    Text(lane.name).tag(lane.id)
                                }
                            }
                            .labelsHidden()
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.bar)

                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(model.generatedTickets) { ticket in
                                    GeneratedTicketRow(ticket: ticket, targetLane: selectedLane)
                                }
                            }
                            .padding()
                        }
                    }
                }
            }
            .navigationTitle("Quick Create")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if model.generatedTickets.isEmpty {
                        Button("Generate") {
                            Task { await model.generateTicketsFromInput(input) }
                        }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isGeneratingTickets)
                    } else {
                        Button("Create All") {
                            Task {
                                await model.createAllGeneratedTickets(in: selectedLane)
                                dismiss()
                            }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                AISettingsSheet().environment(model)
            }
            .onAppear {
                // Set default lane
                if selectedLaneID.isEmpty, let defaultLane = model.quickCreateDefaultLane {
                    selectedLaneID = defaultLane.id
                }
            }
        }
    }
}

/// A row showing a generated ticket with create/remove actions.
private struct GeneratedTicketRow: View {
    @Environment(AppModel.self) private var model
    let ticket: AIGeneratedTicket
    var targetLane: Lane?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ticket.title)
                    .font(.headline)
                Spacer()
                Button {
                    Task { await model.createFromGeneratedTicket(ticket, in: targetLane) }
                } label: {
                    Label("Create", systemImage: "plus.circle.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                Button {
                    model.generatedTickets.removeAll { $0.title == ticket.title }
                } label: {
                    Label("Remove", systemImage: "xmark.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

            if !ticket.description.isEmpty {
                Text(ticket.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                if let priority = ticket.priority {
                    chip(priority, color: .orange)
                }
                if let type = ticket.type {
                    chip(type, color: .blue)
                }
                if let lane = ticket.lane {
                    chip(lane, color: .purple)
                }
                if let epic = ticket.epic {
                    chip(epic, color: .green)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Settings sheet for AI configuration.
struct AISettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Provider") {
                    Picker("AI Provider", selection: $model.aiProvider) {
                        ForEach(AIPontProvider.allCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .onChange(of: model.aiProvider) { _, newProvider in
                        // Auto-select default model when provider changes
                        model.aiModel = newProvider.defaultModel
                    }
                }
                Section("Model") {
                    Picker("Model", selection: $model.aiModel) {
                        ForEach(model.aiProvider.recommendedModels, id: \.self) { m in
                            Text(m).tag(m)
                        }
                    }
                }
                if model.aiProvider.needsAPIKey {
                    Section("API Key") {
                        SecureField("API Key", text: $model.aiAPIKey)
                        Text("Your API key is stored locally and never shared.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("On device") {
                        Text(OnDeviceAI.unavailableReason
                             ?? "Runs on this device with Apple Intelligence. No API key, and nothing you type leaves the device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("AI Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.saveAIConfig()
                        dismiss()
                    }
                }
            }
        }
    }
}

/// A single attachment row with a thumbnail (for images) or a file icon.
private struct AttachmentRow: View {
    @Environment(AppModel.self) private var model
    let entry: BoardFileEntry
    @State private var thumb: UIImage?

    static func isImage(_ name: String) -> Bool {
        [".png", ".jpg", ".jpeg", ".gif", ".heic", ".webp", ".bmp", ".tiff"]
            .contains { name.lowercased().hasSuffix($0) }
    }

    private var isImage: Bool { Self.isImage(entry.name) }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4))
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: isImage ? "photo" : "doc").foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            Text(entry.name).font(.callout).lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "square.and.arrow.up").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .task(id: entry.path) {
            guard isImage, thumb == nil else { return }
            if let data = await model.readAttachment(path: entry.path), let img = UIImage(data: data) {
                thumb = img
            }
        }
    }
}

/// Identifiable temp-file wrapper for the share sheet.
struct CardShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// A SwiftUI wrapper around the system share / open-in sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// An image attachment shown full width; tap to open it in Quick Look (zoom, share).
private struct AttachmentImage: View {
    @Environment(AppModel.self) private var model
    let entry: BoardFileEntry
    @State private var image: UIImage?
    @State private var data: Data?
    @State private var preview: QuickLookItem?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                } else if failed {
                    Label("Couldn't load \(entry.name)", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4))
                        .frame(height: 180)
                        .overlay(ProgressView())
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            Text(entry.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Screenshot \(entry.name)")
        .accessibilityIdentifier("attachmentImage")
        .task(id: entry.path) {
            guard image == nil else { return }
            if let loaded = await model.readAttachment(path: entry.path), let decoded = UIImage(data: loaded) {
                data = loaded
                image = decoded
            } else {
                failed = true
            }
        }
        .quickLook(item: $preview)
    }

    private func open() {
        guard let data else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(entry.name)
        do {
            try data.write(to: url)
            preview = QuickLookItem(url: url)
        } catch {
            model.errorMessage = "Couldn't open \(entry.name): \(error.localizedDescription)"
        }
    }
}
