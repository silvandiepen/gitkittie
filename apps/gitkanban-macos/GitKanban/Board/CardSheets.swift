import AppKit
import GitKanbanKit
import GitKittieKit
import SwiftUI
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
    @State private var showImporter = false

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

    private var navigationTitle: String {
        let title = card.fields.title.isEmpty ? card.fields.id : card.fields.title
        let id = card.fields.id
        if title.isEmpty { return "Task" }
        if id.isEmpty || title == id { return title }
        return title
    }

    private var navigationSubtitle: String? {
        let id = card.fields.id
        let title = card.fields.title
        if id.isEmpty || title.isEmpty || id == title { return nil }
        return id
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .navigationSubtitle(navigationSubtitle ?? "")
                .confirmationDialog("Delete this task?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { Task { await model.deleteCard(card); dismiss() } }
                }
                .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                    handleImport(result)
                }
                .task { await loadAttachments() }
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear(perform: seed)
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

    private func saveAttachment(_ entry: BoardFileEntry) async {
        guard let data = await model.readAttachment(path: entry.path) else { return }
        Platform.save(data: data, suggestedName: entry.name)
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
                // Metadata chips at top (compact)
                metadata

                // Description is primary content - shown immediately
                if card.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No description.").font(.body).foregroundStyle(.secondary)
                        .frame(minHeight: 100, alignment: .topLeading)
                } else {
                    MarkdownWebView(markdown: card.body).frame(minHeight: 180)
                }

                // Attachments: only show if present or expanded via add button
                if !attachments.isEmpty || showImporter {
                    Divider()
                    attachmentsSection
                } else {
                    // Compact add attachment button when no attachments
                    HStack {
                        Spacer()
                        Button { showImporter = true } label: {
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

    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Attachments").font(.subheadline.weight(.medium))
                Spacer()
                Button { showImporter = true } label: { Label("Add", systemImage: "paperclip").font(.caption) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
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
        }
    }

    @ViewBuilder private var metadata: some View {
        let cfg = config ?? EffectiveConfig()
        HStack(spacing: 6) {
            if let lane = laneForStatus { chip(lane.name, color: laneColor(lane, cfg)) }
            if let p = card.fields.priority, let color = PriorityPalette.color(p, priorities) { chip(p, color: color) }
            if let t = card.fields.type { chip(t, color: .secondary) }
            if let e = card.fields.epic { chip(epics.first { $0.id == e }?.name ?? e, color: .purple) }
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
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Edit") { editing = true }
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
                TextEditor(text: $body_).frame(minHeight: 200)
                    .font(.system(.body, design: .monospaced))
            }
        }
        .formStyle(.grouped)
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
}

/// Card detail view optimized for the inspector (side panel).
/// Shows the same content as CardDetailSheet but in a format suited for always-visible side panel.
struct CardDetailInspector: View {
    @Environment(AppModel.self) private var model
    let card: Card

    @State private var editing = false
    @State private var confirmDelete = false
    @State private var attachments: [BoardFileEntry] = []
    @State private var showImporter = false

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header: title + ID + actions
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text(card.fields.title.isEmpty ? card.fields.id : card.fields.title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(4)
                        Spacer(minLength: 12)
                        HStack(spacing: 8) {
                            if editing {
                                Button("Cancel") {
                                    seeded = false
                                    seed()
                                    editing = false
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)

                                Button("Save") {
                                    Task {
                                        await model.updateCard(card, title: title, laneID: laneID, priority: priority,
                                                               type: type, assignee: assignee, epic: epic, body: body_)
                                        editing = false
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                            } else {
                                Button("Edit") { editing = true }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.tint)

                                Menu {
                                    Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .foregroundStyle(.secondary)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }

                            Button { model.selectedCard = nil } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(4)
                                    .background(Circle().fill(.quaternary))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !card.fields.id.isEmpty && card.fields.id != card.fields.title {
                        Text(card.fields.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }

                // Metadata chips
                metadata

                // Content
                if editing {
                    editFormInline
                } else {
                    readContent
                }

                // Attachments
                if !attachments.isEmpty {
                    attachmentsSection
                }

                // Add attachment link
                HStack {
                    Spacer()
                    Button { showImporter = true } label: {
                        Label("Add Attachment", systemImage: "paperclip")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(20)
        }
        .contextMenu { cardMenu(card, model: model) }
        .confirmationDialog("Delete this task?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await model.deleteCard(card)
                    model.selectedCard = nil
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .task { await loadAttachments() }
        .onAppear(perform: seed)
        .onChange(of: card.id) { seed() }
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

    private func saveAttachment(_ entry: BoardFileEntry) async {
        guard let data = await model.readAttachment(path: entry.path) else { return }
        Platform.save(data: data, suggestedName: entry.name)
    }

    @ViewBuilder
    private var readContent: some View {
        // Description rendered with Nizel markdown - auto-sizing
        // Strip the first h1 if it matches the card title (already shown in header)
        let body = stripLeadingTitle(card.body, title: card.fields.title)
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("No description.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        } else {
            MarkdownWebView(markdown: body, compact: true)
        }
    }

    private func stripLeadingTitle(_ markdown: String, title: String) -> String {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        // Check for "# Title" at the start
        if trimmed.hasPrefix("# ") {
            let lines = trimmed.components(separatedBy: .newlines)
            if let firstLine = lines.first {
                let headingText = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if headingText.lowercased() == title.lowercased() || headingText.isEmpty {
                    // Remove the first line
                    return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return markdown
    }

    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Attachments").font(.subheadline.weight(.medium))
                Spacer()
                Button { showImporter = true } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
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
        }
    }

    @ViewBuilder private var metadata: some View {
        let cfg = config ?? EffectiveConfig()
        FlowLayout(spacing: 6) {
            if let lane = laneForStatus { chip(lane.name, color: laneColor(lane, cfg)) }
            if let p = card.fields.priority, let color = PriorityPalette.color(p, priorities) { chip(p, color: color) }
            if let t = card.fields.type { chip(t, color: .secondary) }
            if let e = card.fields.epic { chip(epics.first { $0.id == e }?.name ?? e, color: .purple) }
            if let a = card.fields.assignee {
                HStack(spacing: 3) {
                    Image(systemName: "person.crop.circle")
                    Text("@\(a)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private var editFormInline: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title
            VStack(alignment: .leading, spacing: 4) {
                Text("Title").font(.caption).foregroundStyle(.secondary)
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }

            // Lane & Priority
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lane").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $laneID) {
                        ForEach(lanes) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                }
                if !priorities.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Priority").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $priority) {
                            Text("None").tag("")
                            ForEach(priorities, id: \.id) { Text($0.name ?? $0.id).tag($0.id) }
                        }
                        .labelsHidden()
                    }
                }
            }

            // Type & Assignee
            HStack(spacing: 12) {
                if !types.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Type").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $type) {
                            Text("None").tag("")
                            ForEach(types, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Assignee").font(.caption).foregroundStyle(.secondary)
                    if users.isEmpty {
                        TextField("Assignee", text: $assignee)
                            .textFieldStyle(.plain)
                            .padding(6)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    } else {
                        Picker("", selection: $assignee) {
                            Text("Unassigned").tag("")
                            ForEach(users, id: \.id) { Text($0.name ?? $0.id).tag($0.id) }
                        }
                        .labelsHidden()
                    }
                }
            }

            // Description
            VStack(alignment: .leading, spacing: 4) {
                Text("Description").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $body_)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 100)
                    .padding(6)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
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
}

/// Simple flow layout for chips that wraps to next line.
private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalHeight = max(totalHeight, y + rowHeight)
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
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
                Section("Description") { TextEditor(text: $body_).frame(minHeight: 140) }
            }
            .formStyle(.grouped)
            .navigationTitle("New Task")
            .onAppear { if laneID.isEmpty { laneID = lane.id } }
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
                Section("API Key") {
                    SecureField("API Key", text: $model.aiAPIKey)
                        .textFieldStyle(.roundedBorder)
                    Text("Your API key is stored locally and never shared.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
