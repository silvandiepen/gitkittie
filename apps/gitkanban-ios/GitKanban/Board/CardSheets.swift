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
    @State private var showActivity = false
    @State private var showDue = false
    @State private var showNewLabel = false
    @State private var newLabel = ""

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
                .navigationTitle(editing ? navigationTitle : "")
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $showActivity) {
                    NavigationStack { TaskActivityView(cardID: card.id) }.environment(model)
                        .presentationDetents([.medium, .large])
                }
                .sheet(isPresented: $showDue) { dueSheet.presentationDetents([.medium]) }
                .alert("New Label", isPresented: $showNewLabel) {
                    TextField("Label", text: $newLabel)
                    Button("Add") {
                        let label = newLabel.trimmingCharacters(in: .whitespaces)
                        newLabel = ""
                        if !label.isEmpty { Task { await model.setCardTags(current, current.fields.tags + [label]) } }
                    }
                    Button("Cancel", role: .cancel) { newLabel = "" }
                }
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

    /// The description without a repeated "# Title" and without the activity log.
    /// The description as the rendered page has it, and as the task had it when it was shown.
    @State private var pageText = ""
    @State private var shownNotes = ""

    private var notes: String {
        CardActivity.split(stripLeadingTitle(current.body, title: current.fields.title)).notes
    }

    /// What was typed on the rendered description: written when the cursor leaves it.
    private func savePage() {
        guard pageText != shownNotes else { return }
        shownNotes = pageText
        let card = current
        let fields = card.fields
        let whole = card.body.trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading "# Title" is not shown in the description; it stays in the file.
        let hadHeading = stripLeadingTitle(card.body, title: fields.title).trimmingCharacters(in: .whitespacesAndNewlines) != whole
        let text = CardActivity.join(notes: pageText, log: CardActivity.split(card.body).log)
        Task {
            await model.updateCard(card, title: fields.title, laneID: model.location(ofCard: card)?.id ?? "",
                                   priority: fields.priority ?? "", type: fields.type ?? "",
                                   assignee: fields.assignee ?? "", epic: fields.epic ?? "",
                                   body: hadHeading ? "# \(fields.title)\n\n\(text)" : text)
        }
    }

    private var readView: some View {
        let card = current
        let fields = card.fields
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        if let priority = fields.priority { PriorityBadge(id: priority, priorities: priorities) }
                        if !fields.id.isEmpty && fields.id != fields.title {
                            Text(fields.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    Text(fields.title.isEmpty ? fields.id : fields.title)
                        .font(.title.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 20) {
                        Label(fields.assignee.map { "@\($0)" } ?? "No assignee", systemImage: "person")
                        Button { showDue = true } label: {
                            Label(CardDates.short(fields.due, year: true) ?? "No due date", systemImage: "calendar")
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Changes the due date")
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }

                if !fields.tags.isEmpty || fields.type != nil || fields.epic != nil {
                    FlowLayout(spacing: 8) {
                        if let epic = fields.epic { LabelChip(text: epics.first { $0.id == epic }?.name ?? epic, color: .purple) }
                        ForEach(fields.tags, id: \.self) { LabelChip(text: $0) }
                        if let type = fields.type { LabelChip(text: type, color: .secondary) }
                    }
                }

                if isCheckedOff { readBanner }

                Text("Details").font(.headline)
                details(card)

                // The description: rendered, and edited where it is read.
                RichMarkdownEditor(text: $pageText, fontSize: 17, minHeight: 120, onEndEditing: savePage)
                    .onAppear { pageText = notes; shownNotes = notes }
                    // The task changed underneath: show that, unless something is being typed here.
                    .onChange(of: current.body) { _, _ in
                        let fresh = notes
                        if pageText == shownNotes { pageText = fresh }
                        shownNotes = fresh
                    }
                    .onDisappear(perform: savePage)

                // Review requests linked to this card (`card:` in their review.md).
                let cardReviews = model.reviews(for: card)
                if !cardReviews.isEmpty {
                    Divider()
                    Button { showCardReviews = true } label: {
                        let pending = cardReviews.reduce(0) { $0 + $1.summary.pending }
                        Label(pending > 0 ? "\(pending) waiting for review" : "\(cardReviews.count) review\(cardReviews.count == 1 ? "" : "s")",
                              systemImage: "checkmark.seal")
                    }
                }

                if !attachments.isEmpty {
                    Divider()
                    attachmentsSection
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 24)
        }
        .background(Theme.window.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { actionBar(card) }
    }

    /// Status, priority, assignee, product and labels: each row opens its choices.
    private func details(_ card: Card) -> some View {
        let cfg = config ?? EffectiveConfig()
        let fields = card.fields
        let lane = model.location(ofCard: card) ?? laneForStatus
        return VStack(spacing: 0) {
            detailRow("Status", "circle.dotted.circle") {
                HStack(spacing: 7) {
                    Circle().fill(lane.map { laneColor($0, cfg) } ?? .secondary).frame(width: 10, height: 10)
                    Text(lane?.name ?? "No lane")
                }
            } options: {
                ForEach(lanes.filter { !$0.folder.isEmpty }) { option in
                    Button { Task { await model.moveCard(card, to: option) } } label: { check(option.name, option.id == lane?.id) }
                }
            }
            Divider().padding(.leading, 46)
            detailRow("Priority", "flag") {
                if let priority = fields.priority {
                    HStack(spacing: 7) {
                        Circle().fill(PriorityPalette.color(priority, priorities) ?? .gray).frame(width: 10, height: 10)
                        Text(priority).foregroundStyle(PriorityPalette.color(priority, priorities) ?? .primary)
                    }
                } else { Text("None").foregroundStyle(.tertiary) }
            } options: {
                Button { set(card, "priority", nil) } label: { check("None", fields.priority == nil) }
                ForEach(priorities, id: \.id) { option in
                    Button { set(card, "priority", option.id) } label: { check(option.name ?? option.id, fields.priority == option.id) }
                }
            }
            Divider().padding(.leading, 46)
            detailRow("Assignee", "person") {
                if let assignee = fields.assignee { Text("@\(assignee)") } else { Text("Unassigned").foregroundStyle(.tertiary) }
            } options: {
                Button { set(card, "assignee", nil) } label: { check("Unassigned", fields.assignee == nil) }
                ForEach(users, id: \.id) { user in
                    Button { set(card, "assignee", user.id) } label: { check(user.name ?? user.id, fields.assignee == user.id) }
                }
            }
            if !model.products.isEmpty || fields.product != nil {
                Divider().padding(.leading, 46)
                detailRow("Product", "shippingbox") {
                    if let id = fields.product { Text(model.products.first { $0.id == id }?.name ?? id) } else { Text("None").foregroundStyle(.tertiary) }
                } options: {
                    Button { set(card, "product", nil) } label: { check("None", fields.product == nil) }
                    ForEach(model.products) { product in
                        Button { set(card, "product", product.id) } label: { check(product.name, fields.product == product.id) }
                    }
                }
            }
            Divider().padding(.leading, 46)
            detailRow("Labels", "tag") {
                if fields.tags.isEmpty { Text("None").foregroundStyle(.tertiary) } else { Text(fields.tags.joined(separator: ", ")).lineLimit(1) }
            } options: {
                let all = Array(Set(model.boardTags + fields.tags)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                ForEach(all, id: \.self) { label in
                    Button {
                        let next = fields.tags.contains(label) ? fields.tags.filter { $0 != label } : fields.tags + [label]
                        Task { await model.setCardTags(card, next) }
                    } label: { check(label, fields.tags.contains(label)) }
                }
                Divider()
                Button("New Label…", systemImage: "plus") { showNewLabel = true }
            }
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
    }

    private func set(_ card: Card, _ key: String, _ value: String?) {
        Task { await model.setCardField(card, [key: value]) }
    }

    @ViewBuilder private func check(_ text: String, _ selected: Bool) -> some View {
        if selected { Label(text, systemImage: "checkmark") } else { Text(text) }
    }

    private func detailRow<Value: View, Options: View>(_ name: String, _ symbol: String,
                                                       @ViewBuilder value: () -> Value,
                                                       @ViewBuilder options: () -> Options) -> some View {
        Menu(content: options) {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22)
                Text(name).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                value().foregroundStyle(.primary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }

    /// Under the task: done, edit, activity, attach, and the rest.
    private func actionBar(_ card: Card) -> some View {
        let entries = CardActivity.count(in: card.body)
        let doneLane = lanes.first { $0.terminal == true && !$0.folder.isEmpty }
        return HStack {
            Button {
                if !isCheckedOff, let doneLane { Task { await model.moveCard(card, to: doneLane) } }
            } label: {
                Image(systemName: "checkmark").font(.body.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(isCheckedOff ? Color.green : Color.accentColor, in: Circle())
            }
            .disabled(isCheckedOff || doneLane == nil)
            .accessibilityLabel(isCheckedOff ? "Done" : "Move to \(doneLane?.name ?? "done")")
            .accessibilityIdentifier("taskDone")
            Spacer()
            Button { editing = true } label: { Image(systemName: "pencil").frame(width: 44, height: 44) }
                .accessibilityLabel("Edit")
                .accessibilityIdentifier("taskEdit")
            Spacer()
            Button { showActivity = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left")
                    if entries > 0 { Text("\(entries)").font(.callout.monospacedDigit()) }
                }
                .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Activity, \(entries) entr\(entries == 1 ? "y" : "ies")")
            .accessibilityIdentifier("taskActivity")
            Spacer()
            addAttachmentMenu { Image(systemName: "photo").frame(width: 44, height: 44) }
                .accessibilityLabel("Add attachment")
            Spacer()
            Menu {
                cardMenu(card, model: model)
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
            .accessibilityLabel("More")
        }
        .font(.title3)
        .foregroundStyle(.primary)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, 16).padding(.bottom, 4)
    }

    private var dueSheet: some View {
        NavigationStack {
            VStack {
                DatePicker("Due", selection: Binding(
                    get: { current.fields.due.flatMap(CardDates.date) ?? Date() },
                    set: { day in Task { await model.setCardDue(current, day) } }
                ), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(.horizontal)
                Spacer(minLength: 0)
            }
            .navigationTitle("Due Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if current.fields.due != nil {
                        Button("No Due Date", role: .destructive) { showDue = false; Task { await model.setCardDue(current, nil) } }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showDue = false } }
            }
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

    @ToolbarContentBuilder private var readToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Done")
                .accessibilityIdentifier("taskClose")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button("Edit", systemImage: "pencil") { editing = true }
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } label: { Image(systemName: "ellipsis") }
            .accessibilityLabel("More")
            if let url = model.githubURL(for: card) {
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
            }
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
                    let text = CardActivity.join(notes: body_, log: CardActivity.split(current.body).log)
                    await model.updateCard(card, title: title, laneID: laneID, priority: priority,
                                           type: type, assignee: assignee, epic: epic, body: text)
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
        // The activity log is not edited here: it is put back under the text on save.
        body_ = CardActivity.split(card.body.trimmingCharacters(in: .whitespacesAndNewlines)).notes
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
    /// Why the last draft gave nothing, shown under the Enhance button.
    @State private var draftProblem: String?
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
                if !images.isEmpty { NoDraftingNotice(app: model) }
                Section {
                    TextField("Title", text: $title)
                    Picker("Lane", selection: $laneID) {
                        ForEach(lanes) { Text($0.name).tag($0.id) }
                    }
                    if ImageTaskDrafter.provider(model) != nil {
                        Button { Task { await enhance() } } label: {
                            HStack {
                                Label("Enhance", systemImage: "wand.and.stars")
                                if isDrafting { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(isDrafting || (title.trimmingCharacters(in: .whitespaces).isEmpty
                                                 && body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty))
                        .accessibilityIdentifier("newTaskEnhanceButton")
                    }
                } header: {
                    Text("New Task")
                } footer: {
                    if let draftProblem {
                        Text(draftProblem).foregroundStyle(.red)
                    } else if ImageTaskDrafter.provider(model) != nil {
                        Text("Type a rough note, then Enhance writes the title and description from it.")
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
            .onAppear {
                if laneID.isEmpty { laneID = lane.id }
                fill(from: model.takeNewTaskRequest())
            }
            // Another app asked for a task while this sheet is up (Make Task in Mail, GKM-033).
            .onChange(of: model.newTaskRequest) { _, request in
                if request != nil { fill(from: model.takeNewTaskRequest()) }
            }
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
                        // The card, then each image in its attachments folder (the
                        // marks listed in the description), as the share sheet and the Mac do.
                        let model = model, lane = targetLane, images = images.taskImages
                        let (title, notes, priority, type, assignee, epic) = (title, body_, priority, type, assignee, epic)
                        dismiss()
                        Task {
                            await model.createTask(
                                fromImages: images, title: title, lane: lane,
                                priority: priority.isEmpty ? nil : priority,
                                type: type.isEmpty ? nil : type,
                                assignee: assignee.isEmpty ? nil : assignee,
                                epic: epic.isEmpty ? nil : epic,
                                notes: notes
                            )
                        }
                    }
                    // With an image a title is written if none is given. While it is being
                    // written, creating would save the task without it.
                    .disabled(isDrafting || (title.trimmingCharacters(in: .whitespaces).isEmpty && images.isEmpty))
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

    /// Takes in what another app asked for (Make Task in Mail, GKM-033), keeping what was typed.
    private func fill(from request: NewTaskRequest?) {
        guard let request else { return }
        (title, body_) = request.filling(title: title, body: body_)
    }

    /// "Enhance": what is typed (and the images, if any) are pointers, and the draft
    /// replaces the title and description. Why nothing came back is said in `draftProblem`.
    private func enhance() async {
        guard !isDrafting else { return }
        let pointers = [title, body_].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
        guard !pointers.isEmpty || !images.isEmpty else { return }
        isDrafting = true
        draftProblem = nil
        var known = recognizedText
        let ticket = await ImageTaskDrafter.draft(app: model, images: images.taskImages, pointers: pointers, recognizedText: &known)
        recognizedText = known
        isDrafting = false
        guard let ticket else {
            draftProblem = "The task was not written: \(model.aiError ?? OnDeviceAI.unavailableReason ?? "the model gave nothing back.")"
            return
        }
        title = ticket.title; draftedTitle = ticket.title
        body_ = ticket.description; draftedBody = ticket.description
        if priority.isEmpty, let suggested = ticket.priority, priorities.contains(where: { $0.id == suggested }) { priority = suggested }
        if type.isEmpty, let suggested = ticket.type, types.contains(suggested) { type = suggested }
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
        let ticket = await ImageTaskDrafter.draft(app: model, images: images.taskImages, pointers: own, recognizedText: &known)
        recognizedText = known
        isDrafting = false
        if let ticket {
            // Only where nothing was typed while the draft was being written.
            if open(title, draftedTitle), title == titleAtStart { title = ticket.title; draftedTitle = ticket.title }
            if open(body_, draftedBody), body_ == bodyAtStart { body_ = ticket.description; draftedBody = ticket.description }
            if priority.isEmpty, let suggested = ticket.priority, priorities.contains(where: { $0.id == suggested }) { priority = suggested }
            if type.isEmpty, let suggested = ticket.type, types.contains(suggested) { type = suggested }
        } else {
            if let error = model.aiError { draftProblem = "The task was not written: \(error)" }
            if open(title, draftedTitle), let comment = ImageTaskDrafter.firstComment(images.taskImages) {
                title = comment
                draftedTitle = comment
            }
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


/// A task's activity log, newest first, with a field to add a comment to it.
struct TaskActivityView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let cardID: String
    @State private var comment = ""
    @State private var isSending = false
    @FocusState private var focused: Bool

    private var card: Card? { model.card(withID: cardID) }

    var body: some View {
        let entries = card.map { CardActivity.entries(in: $0.body) } ?? []
        List {
            if entries.isEmpty {
                Text("Nothing yet. A comment starts the log.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(entries.reversed()) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Avatar(name: entry.author, size: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(entry.author ?? "Note").font(.callout.weight(.semibold))
                            if let date = entry.date {
                                Text(date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(MarkdownPage.inline(entry.text)).font(.callout)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.plain)
        .themedList()
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                Avatar(name: model.reviewerID, size: 28)
                TextField("Add a comment…", text: $comment, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .accessibilityIdentifier("taskCommentField")
                if isSending { ProgressView() } else {
                    Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Add comment")
                        .accessibilityIdentifier("taskCommentSend")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .padding(.horizontal, 12).padding(.bottom, 6)
        }
    }

    private func send() {
        guard let card, !isSending else { return }
        let text = comment
        isSending = true
        Task {
            if await model.addComment(card, text) { comment = "" }
            isSending = false
        }
    }
}
