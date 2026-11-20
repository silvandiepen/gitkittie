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
            Picker("Project", selection: $share.destinationID) {
                ForEach(share.destinations) { destination in
                    Text(destination.label).tag(destination.id)
                }
            }
            .onChange(of: share.destinationID) { _, _ in Task { await share.openDestination() } }
            .accessibilityIdentifier("shareProjectPicker")

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
