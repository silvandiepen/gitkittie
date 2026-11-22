import AppKit
import GitKanbanKit
import GitKittieKit
import SwiftUI
import UniformTypeIdentifiers

/// The task in the side panel. There is no edit mode: the title and the description are
/// always editable where they are shown (the description as Markdown styled while you
/// type), the chips are menus, and a green check appears when there is something to save.
struct CardDetailInspector: View {
    @Environment(AppModel.self) private var model
    /// The card that was selected. The panel shows `current`, its latest version on the board.
    let card: Card
    /// Set when the task is shown in a window of its own: closing then closes that window.
    var onClose: (() -> Void)?

    @State private var confirmDelete = false
    @State private var attachments: [BoardFileEntry] = []
    @State private var showImporter = false

    // What is being typed, and what it started from (the difference is what the check saves).
    @State private var title = ""
    @State private var body_ = ""
    @State private var baseTitle = ""
    @State private var baseBody = ""
    @State private var seededID: String?
    @State private var hasTitleHeading = false
    @State private var editorHeight: CGFloat = 160
    @State private var isSaving = false

    private var config: EffectiveConfig? { model.board?.config }
    private var lanes: [Lane] { config?.lanes ?? [] }
    private var priorities: [Priority] { config?.priorities ?? [] }
    private var users: [User] { config?.users ?? [] }
    private var types: [String] { config?.types ?? [] }
    private var epics: [Epic] { config?.epics ?? [] }

    /// The card as the board has it now: the selected copy goes stale after any change.
    private var current: Card {
        guard let board = model.board else { return card }
        for column in board.columns {
            if let found = column.cards.first(where: { $0.id == card.id }) { return found }
        }
        return board.uncategorised.first { $0.id == card.id } ?? card
    }

    private func lane(of card: Card) -> Lane? { model.location(ofCard: card) ?? lanes.first { $0.status == card.fields.status } }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDirty: Bool { title != baseTitle || body_ != baseBody }

    enum Tab: String, CaseIterable, Identifiable {
        case details = "Details", activity = "Activity", files = "Files"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .details
    @State private var comment = ""
    @State private var isSendingComment = false
    @State private var showDue = false
    @State private var showNewLabel = false
    @State private var newLabel = ""
    @FocusState private var commentFocused: Bool

    var body: some View {
        let card = current
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    topBar(card)
                    heading(card)
                    labels(card)
                    tabBar(card)
                    switch tab {
                    case .details: details(card)
                    case .activity: activity(card)
                    case .files: files
                    }
                }
                .padding(20)
            }
            Divider()
            commentBar(card)
        }
        .alert("New Label", isPresented: $showNewLabel) {
            TextField("Label", text: $newLabel)
            Button("Add") {
                let label = newLabel.trimmingCharacters(in: .whitespaces)
                newLabel = ""
                if !label.isEmpty { Task { await model.setCardTags(card, card.fields.tags + [label]) } }
            }
            Button("Cancel", role: .cancel) { newLabel = "" }
        }
        // Closing the window keeps what was typed, like the side panel's close button does.
        .onDisappear { if onClose != nil, isDirty { save(current) } }
        .confirmationDialog("Delete this task?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await model.deleteCard(card)
                    dismissPanel()
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .task(id: self.card.id) { await loadAttachments() }
        .onAppear { seed(from: card) }
        // Another card in the panel: what was typed for the previous one is saved first.
        .onChange(of: self.card.id) { old, _ in
            if isDirty, let previous = model.card(withID: old) { write(previous, title: title, body: body_) }
            seed(from: current)
        }
        // The card changed underneath (someone else, another device): show that, unless
        // something is being typed here.
        .onChange(of: card.body) { _, _ in if !isDirty { seed(from: current) } }
        .onChange(of: card.fields.title) { _, _ in if !isDirty { seed(from: current) } }
        // Two fingers to the right on the trackpad pushes the panel away.
        .background(SwipeRightToClose { close(current) })
    }

    // MARK: Editing

    private func seed(from card: Card) {
        seededID = card.id
        title = card.fields.title
        // A leading "# Title" repeats the title field above it: it is kept out of the
        // editor and written back (with the current title) on save.
        let text = card.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("# "),
           first.dropFirst(2).trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(title) == .orderedSame {
            hasTitleHeading = true
            body_ = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            hasTitleHeading = false
            body_ = text
        }
        // The activity log has its own tab: the notes are the text without it.
        body_ = CardActivity.split(body_).notes
        baseTitle = title
        baseBody = body_
    }

    private func revert() {
        title = baseTitle
        body_ = baseBody
    }

    private func save(_ card: Card) {
        guard isDirty, !trimmedTitle.isEmpty else { return }
        write(card, title: trimmedTitle, body: body_)
        title = trimmedTitle
        baseTitle = title
        baseBody = body_
    }

    /// Write a card's title and description; every other field stays what it is.
    private func write(_ card: Card, title: String, body: String) {
        let fields = card.fields
        let laneID = lane(of: card)?.id ?? ""
        let newTitle = title.isEmpty ? fields.title : title
        // The log as the task has it now: a comment may have been added while this was typed.
        let notes = CardActivity.join(notes: body, log: CardActivity.split(card.body).log)
        let fullBody = hasTitleHeading ? "# \(newTitle)\n\n\(notes)" : notes
        isSaving = true
        Task {
            await model.updateCard(card, title: newTitle, laneID: laneID,
                                   priority: fields.priority ?? "", type: fields.type ?? "",
                                   assignee: fields.assignee ?? "", epic: fields.epic ?? "", body: fullBody)
            isSaving = false
        }
    }

    /// The side panel's close button. A window of its own has the window's.
    @ViewBuilder private func closeButton(_ card: Card) -> some View {
        if onClose == nil {
            Button { close(card) } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
        }
    }

    private func dismissPanel() {
        if let onClose { onClose() } else { model.selectedCard = nil }
    }

    /// Closing keeps what was typed: it is saved on the way out.
    private func close(_ card: Card) {
        save(card)
        dismissPanel()
    }

    // MARK: Attachments

    private func loadAttachments() async { attachments = await model.attachments(for: card) }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let name = url.lastPathComponent
        Task { if await model.attachFile(to: card, data: data, filename: name) { await loadAttachments() } }
    }

    private func saveAttachment(_ entry: BoardFileEntry) async {
        guard let data = await model.readAttachment(path: entry.path) else { return }
        Platform.save(data: data, suggestedName: entry.name)
    }

    // MARK: Header

    private func topBar(_ card: Card) -> some View {
        HStack(spacing: 12) {
            if !card.fields.id.isEmpty && card.fields.id != card.fields.title {
                Text(card.fields.id).font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if isDirty {
                Button { revert() } label: {
                    Image(systemName: "arrow.uturn.backward").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Discard changes")
                .accessibilityLabel("Discard changes")
                .keyboardShortcut(.cancelAction)

                Button { save(card) } label: {
                    Image(systemName: "checkmark.circle.fill").font(.title3)
                        .foregroundStyle(trimmedTitle.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.green))
                }
                .buttonStyle(.plain)
                .help("Done (⌘↩)")
                .accessibilityLabel("Done, save changes")
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(trimmedTitle.isEmpty || isSaving)
            }
            if let url = model.githubURL(for: card) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                } label: {
                    Image(systemName: "link").font(.callout).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy link")
                .accessibilityLabel("Copy link")
            }
            Menu { cardMenu(card, model: model) } label: {
                Image(systemName: "ellipsis").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 18).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Task menu")
            closeButton(card)
                .accessibilityLabel("Close")
        }
    }

    private func heading(_ card: Card) -> some View {
        let fields = card.fields
        return VStack(alignment: .leading, spacing: 10) {
            if let priority = fields.priority {
                Menu { priorityOptions(card) } label: { PriorityBadge(id: priority, priorities: priorities) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("Change priority")
            }
            TextField("Title", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title2.weight(.bold))
                .lineLimit(1...5)
                .fixedSize(horizontal: false, vertical: true)
                .onSubmit { save(card) }
            HStack(spacing: 18) {
                Menu { assigneeOptions(card) } label: {
                    Label(fields.assignee.map { "@\($0)" } ?? "No assignee", systemImage: "person")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Change assignee")
                dueButton(card)
            }
        }
    }

    /// The due date, as a button that opens a calendar.
    private func dueButton(_ card: Card) -> some View {
        Button { showDue = true } label: {
            Label(CardDates.short(card.fields.due, year: true) ?? "No due date", systemImage: "calendar")
                .font(.callout).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Change due date")
        .popover(isPresented: $showDue, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                DatePicker("Due", selection: Binding(
                    get: { card.fields.due.flatMap(CardDates.date) ?? Date() },
                    set: { day in Task { await model.setCardDue(card, day) } }
                ), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                HStack {
                    if card.fields.due != nil {
                        Button("No Due Date", role: .destructive) { showDue = false; Task { await model.setCardDue(card, nil) } }
                    }
                    Spacer()
                    Button("Done") { showDue = false }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 280)
        }
    }

    /// The task's labels, then its type: what it is about and what kind of work it is.
    @ViewBuilder private func labels(_ card: Card) -> some View {
        let fields = card.fields
        if !fields.tags.isEmpty || fields.type != nil || fields.epic != nil {
            FlowLayout(spacing: 6) {
                if let epic = fields.epic { LabelChip(text: epics.first { $0.id == epic }?.name ?? epic, color: .purple) }
                ForEach(fields.tags, id: \.self) { LabelChip(text: $0) }
                if let type = fields.type { LabelChip(text: type, color: .secondary) }
            }
        }
    }

    private func tabBar(_ card: Card) -> some View {
        let entries = CardActivity.count(in: card.body)
        return VStack(spacing: 0) {
            HStack(spacing: 22) {
                ForEach(Tab.allCases) { item in
                    Button { tab = item } label: {
                        HStack(spacing: 5) {
                            Text(item.rawValue).font(.callout.weight(tab == item ? .semibold : .regular))
                            if item == .activity, entries > 0 { Text("\(entries)").font(.caption).foregroundStyle(.secondary) }
                            if item == .files, !attachments.isEmpty { Text("\(attachments.count)").font(.caption).foregroundStyle(.secondary) }
                        }
                        .foregroundStyle(tab == item ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .padding(.bottom, 8)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(tab == item ? Color.accentColor : .clear).frame(height: 2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                }
                Spacer()
            }
            Divider()
        }
        .padding(.top, 4)
    }

    // MARK: Details

    @ViewBuilder private func details(_ card: Card) -> some View {
        let cfg = config ?? EffectiveConfig()
        let fields = card.fields
        VStack(spacing: 4) {
            if !lanes.isEmpty {
                let lane = lane(of: card)
                property("Status", "circle.dotted.circle") {
                    HStack(spacing: 7) {
                        Circle().fill(lane.map { laneColor($0, cfg) } ?? .secondary).frame(width: 9, height: 9)
                        Text(lane?.name ?? "No lane")
                    }
                } options: {
                    ForEach(lanes) { option in
                        option_(option.name, selected: option.id == lane?.id) { Task { await model.moveCard(card, to: option) } }
                    }
                }
            }
            if !priorities.isEmpty || fields.priority != nil {
                property("Priority", "flag") {
                    if let priority = fields.priority {
                        HStack(spacing: 7) {
                            Circle().fill(PriorityPalette.color(priority, priorities) ?? .gray).frame(width: 9, height: 9)
                            Text(priority).foregroundStyle(PriorityPalette.color(priority, priorities) ?? .primary)
                        }
                    } else { Text("None").foregroundStyle(.tertiary) }
                } options: { priorityOptions(card) }
            }
            if !users.isEmpty || fields.assignee != nil {
                property("Assignee", "person") {
                    if let assignee = fields.assignee { Label("@\(assignee)", systemImage: "person") } else { Text("Unassigned").foregroundStyle(.tertiary) }
                } options: { assigneeOptions(card) }
            }
            property("Labels", "tag") {
                if fields.tags.isEmpty { Text("None").foregroundStyle(.tertiary) } else {
                    HStack(spacing: 4) {
                        ForEach(fields.tags.prefix(3), id: \.self) { LabelChip(text: $0) }
                        if fields.tags.count > 3 { Text("+\(fields.tags.count - 3)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            } options: {
                let all = Array(Set(model.boardTags + fields.tags)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                ForEach(all, id: \.self) { label in
                    option_(label, selected: fields.tags.contains(label)) {
                        let next = fields.tags.contains(label) ? fields.tags.filter { $0 != label } : fields.tags + [label]
                        Task { await model.setCardTags(card, next) }
                    }
                }
                if !all.isEmpty { Divider() }
                Button("New Label…", systemImage: "plus") { showNewLabel = true }
            }
            if !model.products.isEmpty || fields.product != nil {
                property("Product", "shippingbox") {
                    if let id = fields.product { Label(model.products.first { $0.id == id }?.name ?? id, systemImage: "shippingbox") }
                    else { Text("None").foregroundStyle(.tertiary) }
                } options: {
                    option_("None", selected: fields.product == nil) { set(card, "product", nil) }
                    ForEach(model.products) { product in
                        option_(product.name, selected: fields.product == product.id) { set(card, "product", product.id) }
                    }
                }
            }
            if !epics.isEmpty || fields.epic != nil {
                property("Epic", "square.stack.3d.up") {
                    if let id = fields.epic { Text(epics.first { $0.id == id }?.name ?? id) } else { Text("None").foregroundStyle(.tertiary) }
                } options: {
                    option_("None", selected: fields.epic == nil) { set(card, "epic", nil) }
                    ForEach(epics, id: \.id) { epic in
                        option_(epic.name ?? epic.id, selected: fields.epic == epic.id) { set(card, "epic", epic.id) }
                    }
                }
            }
            if !types.isEmpty || fields.type != nil {
                property("Type", "square.on.circle") {
                    if let type = fields.type { Text(type) } else { Text("None").foregroundStyle(.tertiary) }
                } options: {
                    option_("None", selected: fields.type == nil) { set(card, "type", nil) }
                    ForEach(types, id: \.self) { type in
                        option_(type, selected: fields.type == type) { set(card, "type", type) }
                    }
                }
            }
            if let created = CardDates.short(fields.createdAt, year: true) { fact("Created", "clock", created) }
            if let updated = CardDates.short(fields.updatedAt, year: true) { fact("Updated", "clock.arrow.circlepath", updated) }
        }

        Divider().padding(.vertical, 4)

        Label("Notes", systemImage: "doc.text").font(.callout).foregroundStyle(.secondary)
        // The description: rendered, and edited where it is read. As tall as its text.
        RichMarkdownEditor(text: $body_, fontSize: 13, minHeight: 120, onEndEditing: { save(card) })
    }

    @ViewBuilder private func priorityOptions(_ card: Card) -> some View {
        option_("None", selected: card.fields.priority == nil) { set(card, "priority", nil) }
        ForEach(priorities, id: \.id) { priority in
            option_(priority.name ?? priority.id, selected: card.fields.priority == priority.id) { set(card, "priority", priority.id) }
        }
    }

    @ViewBuilder private func assigneeOptions(_ card: Card) -> some View {
        option_("Unassigned", selected: card.fields.assignee == nil) { set(card, "assignee", nil) }
        ForEach(users, id: \.id) { user in
            option_(user.name ?? user.id, selected: card.fields.assignee == user.id) { set(card, "assignee", user.id) }
        }
    }

    /// One property: its name on the left, its value as a field that opens a menu.
    private func property<Value: View, Options: View>(_ name: String, _ symbol: String,
                                                      @ViewBuilder value: () -> Value,
                                                      @ViewBuilder options: () -> Options) -> some View {
        HStack(spacing: 10) {
            Label(name, systemImage: symbol)
                .font(.callout).foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)
            Menu(content: options) {
                HStack(spacing: 6) {
                    value().font(.callout).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .accessibilityLabel(name)
        }
    }

    /// A property that is read, not set.
    private func fact(_ name: String, _ symbol: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Label(name, systemImage: symbol)
                .font(.callout).foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)
            Text(value).font(.callout).padding(.horizontal, 10).padding(.vertical, 6)
            Spacer(minLength: 0)
        }
    }

    // MARK: Activity

    @ViewBuilder private func activity(_ card: Card) -> some View {
        let entries = CardActivity.entries(in: card.body)
        if entries.isEmpty {
            Text("Nothing yet. A comment below starts the log.")
                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                // Newest first: what happened last is what is asked for.
                ForEach(entries.reversed()) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Avatar(name: entry.author)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(entry.author ?? "Note").font(.callout.weight(.semibold))
                                if let date = entry.date {
                                    Text(date.formatted(.relative(presentation: .named)))
                                        .font(.caption).foregroundStyle(.secondary)
                                        .help(date.formatted(date: .abbreviated, time: .shortened))
                                }
                            }
                            Text(Self.inline(entry.text)).font(.callout).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    /// An entry's text with its inline Markdown (code, links, bold) shown as such.
    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func commentBar(_ card: Card) -> some View {
        HStack(spacing: 10) {
            Avatar(name: model.reviewerID)
            TextField("Add a comment…", text: $comment, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($commentFocused)
                .onSubmit { send(card) }
            if isSendingComment {
                ProgressView().controlSize(.small)
            } else {
                Button { send(card) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title3)
                        .foregroundStyle(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                }
                .buttonStyle(.plain)
                .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Add comment")
                .accessibilityLabel("Add comment")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func send(_ card: Card) {
        let text = comment
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isSendingComment else { return }
        isSendingComment = true
        Task {
            // What is being typed in the notes is saved first, so the comment lands on it.
            if isDirty { save(card) }
            if await model.addComment(current, text) { comment = ""; tab = .activity }
            isSendingComment = false
        }
    }

    // MARK: Files

    private var files: some View {
        VStack(alignment: .leading, spacing: 8) {
            if attachments.isEmpty {
                Text("No files on this task.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(attachments, id: \.path) { entry in
                AttachmentRow(entry: entry)
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await saveAttachment(entry) } }
                    .contextMenu {
                        Button("Save…", systemImage: "square.and.arrow.down") { Task { await saveAttachment(entry) } }
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            Task { await model.deleteAttachment(path: entry.path); await loadAttachments() }
                        }
                    }
            }
            Button { showImporter = true } label: { Label("Add File…", systemImage: "paperclip") }
                .buttonStyle(.bordered)
        }
    }

    private func set(_ card: Card, _ key: String, _ value: String?) {
        Task { await model.setCardField(card, [key: value]) }
    }

    @ViewBuilder private func option_(_ text: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected { Label(text, systemImage: "checkmark") } else { Text(text) }
        }
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
    @State private var product = ""
    @State private var body_ = ""

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
                    if !model.products.isEmpty {
                        Picker("Product", selection: $product) {
                            Text("None").tag("")
                            ForEach(model.products) { item in
                                Text(item.prefix.map { "\(item.name) (\($0)-…)" } ?? item.name).tag(item.id)
                            }
                        }
                    }
                }
                Section("Description") { TextEditor(text: $body_).frame(minHeight: 140) }
            }
            .formStyle(.grouped)
            .navigationTitle("New Task")
            .onAppear {
                if laneID.isEmpty { laneID = lane.id }
                // A board filtered on a product starts new tasks in that product.
                if product.isEmpty, let filtered = model.filterProduct { product = filtered }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await model.createTask(
                                title: title, lane: targetLane,
                                priority: priority.isEmpty ? nil : priority,
                                type: type.isEmpty ? nil : type,
                                assignee: assignee.isEmpty ? nil : assignee,
                                epic: epic.isEmpty ? nil : epic,
                                product: product.isEmpty ? nil : product,
                                body: body_
                            )
                            dismiss()
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 520)
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
                            .frame(maxWidth: 200)
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
                ToolbarItem(placement: .automatic) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("AI Settings")
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
        .frame(minWidth: 520, minHeight: 480)
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
                            .textFieldStyle(.roundedBorder)
                        Text("Your API key is stored locally and never shared.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("On device") {
                        Text(OnDeviceAI.unavailableReason
                             ?? "Runs on this Mac with Apple Intelligence. No API key, and nothing you type leaves the device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("AI Settings")
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
        .frame(minWidth: 400, minHeight: 320)
    }
}

/// A single attachment row with a thumbnail (for images) or a file icon.
private struct AttachmentRow: View {
    @Environment(AppModel.self) private var model
    let entry: BoardFileEntry
    @State private var thumb: NSImage?

    private var isImage: Bool {
        [".png", ".jpg", ".jpeg", ".gif", ".heic", ".webp", ".bmp", ".tiff"]
            .contains { entry.name.lowercased().hasSuffix($0) }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4))
                if let thumb {
                    Image(nsImage: thumb).resizable().scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: isImage ? "photo" : "doc").foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            Text(entry.name).font(.callout).lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "square.and.arrow.down").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .task(id: entry.path) {
            guard isImage, thumb == nil else { return }
            if let data = await model.readAttachment(path: entry.path), let img = NSImage(data: data) {
                thumb = img
            }
        }
    }
}


// MARK: - A task in a window of its own

/// Opens a task in its own window (double-click on the board, or "Open in Panel").
struct OpenTaskPanelButton: View {
    @Environment(\.openWindow) private var openWindow
    let card: Card

    var body: some View {
        Button("Open in Panel", systemImage: "arrow.up.forward.square") {
            openWindow(id: TaskPanel.windowID, value: card.fields.id)
        }
    }
}

/// A task as a page of its own: where it is, its title and properties in one row, and
/// its description rendered. Edit switches to the editor of the side panel.
struct TaskPanel: View {
    static let windowID = "task"
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let cardID: String

    @State private var isEditing = false
    @State private var draft = ""
    @State private var draftTitle = ""
    @State private var editorHeight: CGFloat = 300
    /// The description as the rendered page has it, and as the task had it when it was shown.
    @State private var pageText = ""
    @State private var shownNotes = ""
    @State private var comment = ""
    @State private var isSending = false

    private var card: Card? { model.allCards.first { $0.fields.id == cardID } }
    private var config: EffectiveConfig { model.board?.config ?? EffectiveConfig() }

    /// The description without a leading "# Title" (the title is above it) and without the activity log.
    private func notes(_ card: Card) -> (text: String, hasTitleHeading: Bool) {
        let text = card.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("# "),
           first.dropFirst(2).trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(card.fields.title) == .orderedSame {
            return (CardActivity.split(lines.dropFirst().joined(separator: "\n")).notes, true)
        }
        return (CardActivity.split(text).notes, false)
    }

    var body: some View {
        Group {
            if let card {
                page(card).navigationTitle(card.fields.title.isEmpty ? cardID : card.fields.title)
            } else {
                ContentUnavailableView("Task Not on This Board", systemImage: "rectangle.on.rectangle.slash",
                                       description: Text("\(cardID) is not on the board that is open now."))
                    .navigationTitle(cardID)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(Theme.window)
    }

    private func page(_ card: Card) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                path(card)
                if isEditing {
                    TextField("Title", text: $draftTitle, axis: .vertical)
                        .textFieldStyle(.plain).font(.largeTitle.weight(.bold)).lineLimit(1...4)
                } else {
                    Text(card.fields.title.isEmpty ? cardID : card.fields.title)
                        .font(.largeTitle.weight(.bold)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                properties(card)
                Divider()
                if isEditing {
                    MarkdownEditor(text: $draft, contentHeight: $editorHeight, onCommit: { finish(card) })
                        .frame(height: max(editorHeight, 240))
                } else {
                    // Rendered, and edited where it is read. Edit shows the Markdown itself.
                    RichMarkdownEditor(text: $pageText, fontSize: 15, minHeight: 160, onEndEditing: { savePage(card) })
                        .onAppear { pageText = notes(card).text; shownNotes = pageText }
                        // The task changed underneath: show that, unless something is being typed here.
                        .onChange(of: card.body) { _, _ in
                            let fresh = notes(card).text
                            if pageText == shownNotes { pageText = fresh }
                            shownNotes = fresh
                        }
                }
                activity(card)
            }
            .padding(.horizontal, 36).padding(.vertical, 22)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        // Closing the window keeps what was typed.
        .onDisappear { if isEditing { finish(card) } else { savePage(card) } }
    }

    /// Where the task is: board, Tasks, the task. With the way back, Edit and the task's menu.
    private func path(_ card: Card) -> some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 26, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close")
            Image(systemName: "folder").foregroundStyle(.tint)
            Text(model.selectedProject?.name ?? "Board")
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            Text("Tasks")
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            Text(card.fields.title.isEmpty ? cardID : card.fields.title).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            if isEditing {
                Button("Cancel") { isEditing = false }.keyboardShortcut(.cancelAction)
                Button("Done") { finish(card) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draftTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                Button {
                    draft = notes(card).text
                    draftTitle = card.fields.title
                    isEditing = true
                } label: { Label("Edit", systemImage: "pencil") }
                .keyboardShortcut("e")
            }
            Menu { cardMenu(card, model: model) } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 26, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Task menu")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// Priority, status, product, assignee and dates in one row. What can change is a menu.
    private func properties(_ card: Card) -> some View {
        let fields = card.fields
        let lane = model.location(ofCard: card)
        return FlowLayout(spacing: 18) {
            if let priority = fields.priority {
                Menu {
                    ForEach(config.priorities, id: \.id) { option in
                        Button(option.name ?? option.id) { Task { await model.setCardField(card, ["priority": option.id]) } }
                    }
                } label: { PriorityBadge(id: priority, priorities: config.priorities, large: true) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Change priority")
            }
            Menu {
                ForEach(config.lanes.filter { !$0.folder.isEmpty }) { option in
                    Button(option.name) { Task { await model.moveCard(card, to: option) } }
                }
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(lane.map { laneColor($0, config) } ?? .secondary).frame(width: 10, height: 10)
                    Text(lane?.name ?? "No lane").font(.callout.weight(.medium))
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10)))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Change status")
            if let id = fields.product {
                Label(model.products.first { $0.id == id }?.name ?? id, systemImage: "shippingbox").padding(.vertical, 5)
            }
            Menu {
                Button("Unassigned") { Task { await model.setCardField(card, ["assignee": nil]) } }
                ForEach(config.users, id: \.id) { user in
                    Button(user.name ?? user.id) { Task { await model.setCardField(card, ["assignee": user.id]) } }
                }
            } label: { Label(fields.assignee.map { "@\($0)" } ?? "No assignee", systemImage: "person").padding(.vertical, 5) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Change assignee")
            if let due = CardDates.short(fields.due, year: true) { Label("Due \(due)", systemImage: "calendar.badge.clock").padding(.vertical, 5) }
            if let created = CardDates.short(fields.createdAt, year: true) { Label(created, systemImage: "calendar").padding(.vertical, 5).help("Created") }
            if let updated = CardDates.short(fields.updatedAt, year: true) { Label("Updated \(updated)", systemImage: "calendar").padding(.vertical, 5) }
            ForEach(fields.tags, id: \.self) { LabelChip(text: $0) }
        }
        .font(.callout)
    }

    /// What happened to the task, newest first, and a field to add to it.
    @ViewBuilder private func activity(_ card: Card) -> some View {
        let entries = CardActivity.entries(in: card.body)
        Divider().padding(.top, 6)
        Text("Activity").font(.title3.weight(.semibold))
        HStack(spacing: 10) {
            Avatar(name: model.reviewerID)
            TextField("Add a comment…", text: $comment, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...5)
                .onSubmit { send(card) }
            if isSending { ProgressView().controlSize(.small) } else {
                Button { send(card) } label: { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                    .buttonStyle(.plain)
                    .foregroundStyle(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                    .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Add comment")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        ForEach(entries.reversed()) { entry in
            HStack(alignment: .top, spacing: 10) {
                Avatar(name: entry.author)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.author ?? "Note").font(.callout.weight(.semibold))
                        if let date = entry.date {
                            Text(date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                                .help(date.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    Text(MarkdownPage.inline(entry.text)).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func send(_ card: Card) {
        let text = comment
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isSending else { return }
        isSending = true
        Task {
            if await model.addComment(card, text) { comment = "" }
            isSending = false
        }
    }

    /// What was typed on the rendered page: written when the cursor leaves it.
    private func savePage(_ card: Card) {
        guard pageText != shownNotes else { return }
        shownNotes = pageText
        write(card, title: card.fields.title, notes: pageText)
    }

    /// Done: write the title and the description.
    private func finish(_ card: Card) {
        let title = draftTitle.trimmingCharacters(in: .whitespaces)
        isEditing = false
        guard !title.isEmpty else { return }
        guard draft != notes(card).text || title != card.fields.title else { return }
        write(card, title: title, notes: draft)
    }

    /// Writes the title and the description, with the activity log put back under it.
    private func write(_ card: Card, title: String, notes draft: String) {
        let old = notes(card)
        let text = CardActivity.join(notes: draft, log: CardActivity.split(card.body).log)
        let body = old.hasTitleHeading ? "# \(title)\n\n\(text)" : text
        let fields = card.fields
        Task {
            await model.updateCard(card, title: title, laneID: model.location(ofCard: card)?.id ?? "",
                                   priority: fields.priority ?? "", type: fields.type ?? "",
                                   assignee: fields.assignee ?? "", epic: fields.epic ?? "", body: body)
        }
    }
}
