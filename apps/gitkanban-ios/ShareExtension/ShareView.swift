import GitKanbanKit
import GitKittieKit
import SwiftUI

/// The share sheet: which project, a new or an existing task, what is wrong in the image,
/// and the task text, drafted for you while you choose.
struct ShareView: View {
    @Bindable var share: ShareModel
    let onCancel: () -> Void
    let onDone: () -> Void

    /// The image open in the annotation editor.
    @State private var annotating: SharedImage.ID?
    /// The board panel is open.
    @State private var choosingBoard = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(share.target == .new ? "New Task" : "Add to Task")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // While sending, closing is fine: what is not out yet stays saved
                        // and the app sends it.
                        Button(share.phase == .done ? "Close" : "Cancel") {
                            share.phase == .done ? onDone() : onCancel()
                        }
                        .disabled(share.phase == .saving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if share.phase != .done {
                            // Saving is local and instant; the sheet closes and the
                            // sending carries on behind it.
                            Button("Add") {
                                Task {
                                    if await share.save() {
                                        share.sendInBackground()
                                        onDone()
                                    }
                                }
                            }
                            .disabled(!share.canSave)
                            .accessibilityIdentifier("shareAddButton")
                        }
                    }
                }
        }
        .task {
            share.appearance = colorScheme == .dark ? .dark : .light
            share.textSize = UITraitCollection.current.preferredContentSizeCategory
            await share.load()
        }
        .sheet(item: annotatingBinding, onDismiss: { Task { await share.annotationsChanged() } }) { $image in
            AnnotationEditor(image: $image, foundIssues: share.foundIssues)
        }
        .safeAreaInset(edge: .bottom) {
            if share.phase == .saving { sendingBar }
        }
    }

    /// The binding to the image being annotated, for the editor sheet.
    private var annotatingBinding: Binding<Binding<SharedImage>?> {
        Binding(
            get: { $share.images.first { $0.wrappedValue.id == annotating } },
            set: { if $0 == nil { annotating = nil } })
    }

    /// What is being sent, at the bottom of the sheet while it goes out.
    private var sendingBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(share.savingStep).font(.callout.weight(.medium))
            ProgressView(value: share.savingProgress)
                .animation(.easeInOut, value: share.savingProgress)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("shareSendingBar")
    }

    @ViewBuilder private var content: some View {
        if share.phase == .loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if share.destinations.isEmpty {
            ContentUnavailableView(
                "No boards yet",
                systemImage: "rectangle.split.3x1",
                description: Text("Open the Tasks app, add a board, and share again."))
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            NoDraftingNotice(app: share.app)
            projectSection
            if !share.images.isEmpty { imageSection }
            if !share.foundIssues.isEmpty { issuesSection }
            textSection
            Section {
                Toggle("Include device details", isOn: $share.includeDevice)
            } footer: {
                Text("Adds the model, iOS version, screen size, appearance and text size to the task.")
            }
            if let message = share.message {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Sections

    private var projectSection: some View {
        Section {
            // The board, with its repository small under it, opening a panel to choose
            // another: the board is what you are choosing, the repository only says where.
            Button { choosingBoard = true } label: {
                if let destination = share.destination {
                    HStack(spacing: 12) {
                        BoardIcon(board: destination.board)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(destination.board.name).font(.headline).foregroundStyle(.primary)
                            Text(destination.repo.displayName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Board, \(share.destination?.board.name ?? "")")
            .accessibilityHint("Choose another board")
            .accessibilityIdentifier("shareProjectPicker")
            .sheet(isPresented: $choosingBoard) {
                BoardPanel(destinations: share.destinations, chosen: share.destinationID) { id in
                    choosingBoard = false
                    guard id != share.destinationID else { return }
                    share.destinationID = id
                    Task { await share.openDestination() }
                }
            }

            Picker("Add to", selection: $share.target) {
                ForEach(ShareModel.Target.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: share.target) { _, _ in Task { await share.targetChanged() } }

            if share.isLoadingBoard {
                HStack { Text("Loading project"); Spacer(); ProgressView() }
            } else if share.target == .new, !share.lanes.isEmpty {
                Picker("Lane", selection: $share.laneID) {
                    ForEach(share.lanes) { lane in Text(lane.name).tag(lane.id) }
                }
            } else if share.target == .existing {
                NavigationLink {
                    ExistingTaskPicker(share: share)
                } label: {
                    HStack {
                        Text("Task")
                        Spacer()
                        Text(share.existingCard.map { $0.fields.title.isEmpty ? $0.fields.id : $0.fields.title } ?? "Choose")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityIdentifier("shareExistingTask")
            }
        }
        .disabled(share.phase != .ready)
    }

    private var imageSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach($share.images) { $image in
                        if let thumbnail = image.thumbnail {
                            Button { annotating = image.id } label: {
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 160)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(alignment: .bottomTrailing) { annotateBadge(count: image.annotations.count) }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Mark up image")
                            .accessibilityIdentifier("annotateButton")
                        }
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            if share.isAnalyzing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Analyzing the image").foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Tap the image to mark a part of it and say what is wrong.")
        }
    }

    private var issuesSection: some View {
        Section {
            ForEach(share.foundIssues, id: \.self) { issue in
                Button {
                    if share.selectedIssues.contains(issue) { share.selectedIssues.remove(issue) }
                    else { share.selectedIssues.insert(issue) }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: share.selectedIssues.contains(issue) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(share.selectedIssues.contains(issue) ? Color.accentColor : .secondary)
                        Text(issue).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Found in the image")
        } footer: {
            Text("Tick what belongs in the task. They are also offered as comments when you mark up the image.")
        }
    }

    private var textSection: some View {
        Section {
            if share.target == .new {
                TextField(share.isAnalyzing ? "Writing a title…" : "Title (written for you if left empty)", text: $share.title, axis: .vertical)
                    .accessibilityIdentifier("shareTitleField")
            }
            TextField(share.target == .new ? "Notes, or pointers for the draft" : "What to add", text: $share.notes, axis: .vertical)
                .lineLimit(3...10)
            if share.target == .new, !share.types.isEmpty {
                Picker("Type", selection: $share.type) {
                    Text("None").tag("")
                    ForEach(share.types, id: \.self) { Text($0).tag($0) }
                }
            }
            if share.target == .new, !share.priorities.isEmpty {
                Picker("Priority", selection: $share.priority) {
                    Text("None").tag("")
                    ForEach(share.priorities, id: \.id) { priority in Text(priority.name.map { "\(priority.id) · \($0)" } ?? priority.id).tag(priority.id) }
                }
            }
            if let provider = share.analysisProvider {
                Button {
                    Task { await share.analyze(keepingTypedText: false) }
                } label: {
                    HStack {
                        Label("Enhance", systemImage: "wand.and.stars")
                        if share.isAnalyzing { Spacer(); ProgressView() }
                    }
                }
                .disabled(share.isAnalyzing || share.phase != .ready)
                .accessibilityIdentifier("shareEnhanceButton")
                Toggle("Analyze images automatically", isOn: $share.analyzesAutomatically)
                    .accessibilityHint("Uses \(provider.displayName)")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(ImageTaskDrafter.status(share.app))
                if let provider = share.analysisProvider, share.analysisSendsImages {
                    Text("Usage is billed to your \(provider.displayName) account.")
                }
            }
        }
    }

    private func annotateBadge(count: Int) -> some View {
        Label(count == 0 ? "Mark up" : "\(count)", systemImage: "pencil.tip.crop.circle")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .padding(6)
    }
}

/// Choose the task the images belong to, with search.
private struct ExistingTaskPicker: View {
    @Bindable var share: ShareModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var matches: [Card] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return share.cards }
        return share.cards.filter {
            $0.fields.title.lowercased().contains(query) || $0.fields.id.lowercased().contains(query)
        }
    }

    var body: some View {
        List(matches, id: \.fields.id) { card in
            Button {
                share.existingCardID = card.fields.id
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.fields.title.isEmpty ? card.fields.id : card.fields.title)
                            .foregroundStyle(.primary)
                        Text(card.fields.id).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if card.fields.id == share.existingCardID {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle("Choose Task")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if share.cards.isEmpty { ContentUnavailableView("No tasks on this board", systemImage: "tray") }
        }
    }
}

/// A board's own icon in its own colour, as on the home screen.
private struct BoardIcon: View {
    let board: SelectedBoard

    var body: some View {
        Image(systemName: board.icon ?? BoardAppearance.defaultIcon)
            .font(.title3)
            .foregroundStyle(Color(boardColor: board.color))
            .frame(width: 28)
    }
}

/// The boards to share to, in a panel: each repository a small heading, its boards under
/// it, the chosen one ticked. Searchable once there are more than a screenful.
private struct BoardPanel: View {
    let destinations: [ShareDestination]
    let chosen: String
    let onChoose: (String) -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    /// Repositories in the order they are in the app, each with its boards that match.
    private var groups: [(repo: AddedRepo, boards: [ShareDestination])] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        var order: [String] = []
        var byRepo: [String: [ShareDestination]] = [:]
        for destination in destinations {
            guard needle.isEmpty
                || destination.board.name.localizedCaseInsensitiveContains(needle)
                || destination.repo.displayName.localizedCaseInsensitiveContains(needle) else { continue }
            if byRepo[destination.repo.id] == nil { order.append(destination.repo.id) }
            byRepo[destination.repo.id, default: []].append(destination)
        }
        return order.compactMap { id in byRepo[id].map { ($0[0].repo, $0) } }
    }

    var body: some View {
        NavigationStack {
            searchable(List {
                ForEach(groups, id: \.repo.id) { group in
                    Section {
                        ForEach(group.boards) { destination in
                            Button { onChoose(destination.id) } label: {
                                HStack(spacing: 12) {
                                    BoardIcon(board: destination.board)
                                    Text(destination.board.name).foregroundStyle(.primary)
                                    Spacer(minLength: 8)
                                    if destination.id == chosen {
                                        Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(destination.id == chosen ? .isSelected : [])
                            .accessibilityIdentifier("shareBoard-\(destination.board.name)")
                        }
                    } header: {
                        Text(group.repo.displayName)
                    }
                }
                if groups.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            })
            .navigationTitle("Board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Solid, so the form under the panel does not show through the list.
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
    }

    /// A search field only once there are more boards than fit on the panel.
    @ViewBuilder private func searchable(_ list: some View) -> some View {
        if destinations.count > 8 {
            list.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Boards")
        } else {
            list
        }
    }
}
